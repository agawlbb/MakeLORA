import XCTest
import SwiftUI
@testable import MakeLORA

final class VideoFilesImportTests: XCTestCase {
    @MainActor func testPickerOpensReferencesWithoutCopyingBeforeDismissal() {
        let controller = VideoFilesPicker.controller()
        XCTAssertEqual(controller.documentPickerMode, .open)
        XCTAssertTrue(controller.allowsMultipleSelection)
        let source = URL(fileURLWithPath: "/unavailable-provider/movie.mp4")
        var selection: [URL] = [], canceled = false
        let picker = VideoFilesPicker(onSelection: { selection = $0 }, onCancel: { canceled = true })
        let coordinator = VideoFilesPicker.Coordinator(picker)
        coordinator.documentPicker(controller, didPickDocumentsAt: [source])
        XCTAssertEqual(selection, [source], "Selecting a reference must not wait for the file to be readable")
        XCTAssertFalse(canceled)
        coordinator.documentPickerWasCancelled(controller)
        XCTAssertTrue(canceled)
    }

    func testCoordinatedCopyRunsOffMainAndPreservesSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), destination = root.appendingPathComponent("staged.mp4")
        let bytes = Data(repeating: 42, count: 1_200_000)
        try bytes.write(to: source)
        try await CoordinatedFileImport.copy(source: source, destination: destination, coordinate: { _, url, read in
            XCTAssertFalse(Thread.isMainThread)
            read(url)
            return nil
        })
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCanceledProviderReturnsBeforeProviderUnblocksAndDiscardsLateResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), destination = root.appendingPathComponent("staged.mp4")
        try Data([1, 2, 3]).write(to: source)
        let started = expectation(description: "Provider started"), finished = expectation(description: "Provider returned")
        let releaseProvider = DispatchSemaphore(value: 0)
        let task = Task {
            try await CoordinatedFileImport.copy(source: source, destination: destination, coordinate: { _, url, read in
                started.fulfill(); releaseProvider.wait()
                read(url); finished.fulfill()
                return nil
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        releaseProvider.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "A late provider callback must not publish a file")
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testStalledProviderTimesOutWithoutWaitingForItsCallback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), destination = root.appendingPathComponent("staged.mp4")
        try Data([4, 5, 6]).write(to: source)
        let releaseProvider = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Late provider returned")
        do {
            try await CoordinatedFileImport.copy(source: source, destination: destination, timeout: 1, coordinate: { _, url, read in
                releaseProvider.wait(); read(url); finished.fulfill()
                return nil
            })
            XCTFail("Expected a provider timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("On My iPhone/iPad"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        releaseProvider.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCaptionLimitAndMissingFilesCleanUpStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.txt"), destination = root.appendingPathComponent("staged.txt")
        try Data(repeating: 65, count: 1_000_001).write(to: source)
        do {
            try await CoordinatedFileImport.copy(source: source, destination: destination, maximumBytes: 1_000_000)
            XCTFail("Expected caption limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1 MB")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        do {
            try await CoordinatedFileImport.copy(source: root.appendingPathComponent("missing.mp4"), destination: destination)
            XCTFail("Expected unreadable file failure")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
