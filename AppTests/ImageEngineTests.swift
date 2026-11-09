import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import MakeLORACore
@testable import MakeLORA

final class ImageEngineTests: XCTestCase {
    func testHEICImportCropReexportAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            UIColor.blue.setFill(); context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        let heic = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 1, nil) else { throw XCTSkip("HEIC encoder is unavailable on this simulator") }
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("HEIC encoder cannot write on this simulator") }
        let engine = ImageEngine()
        let photo = try await engine.importPhoto(data: heic as Data, name: "source.heic", directory: directory)
        var project = Project(name: "HEIC project")
        project.photos = [photo]
        project.addPair(control: photo.id, target: photo.id)
        project.pairs[0].caption = "Make it brighter ☀️"
        project.pairs[0].controlCrop = Crop(width: 0.5)
        try await engine.synchronize(project, directory: directory, revision: 1)
        let jpg = directory.appendingPathComponent("dataset/control/1.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 120)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("dataset/target/1.txt"), encoding: .utf8), project.pairs[0].caption)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("originals/\(photo.filename)")), heic as Data)
        let originalSize = try Data(contentsOf: jpg)
        project.pairs[0].controlCrop = .full
        project.pairs[0].caption = "Updated caption"
        let archive = try await engine.export(project, directory: directory, revision: 2)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertNotEqual(try Data(contentsOf: jpg), originalSize)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("dataset/target/1.txt"), encoding: .utf8), "Updated caption")
        project.pairs = []
        try await engine.synchronize(project, directory: directory, revision: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("originals/\(photo.filename)").path))
    }
    func testPNGToJPGAndStaleRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        }
        let engine = ImageEngine()
        let photo = try await engine.importPhoto(data: XCTUnwrap(image.pngData()), name: "transparent.png", directory: directory)
        var project = Project(name: "PNG")
        project.photos = [photo]; project.addPair(control: photo.id, target: photo.id)
        project.pairs[0].caption = "Current caption"
        try await engine.synchronize(project, directory: directory, revision: 5)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent("dataset/target/1.jpg") as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        project.pairs[0].caption = "Stale caption"
        try await engine.synchronize(project, directory: directory, revision: 4)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("dataset/target/1.txt"), encoding: .utf8), "Current caption")
        do {
            _ = try await engine.importPhoto(data: Data("not an image".utf8), name: "broken.heic", directory: directory)
            XCTFail("Malformed image should be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Cannot import")) }
    }
    @MainActor func testProjectAutosaveAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        store.create(name: "First")
        let id = try XCTUnwrap(store.project?.id)
        store.update { $0.name = "Renamed" }
        await store.flush()
        let reopened = ProjectStore(root: root)
        let summary = try XCTUnwrap(reopened.projects.first)
        reopened.open(summary)
        XCTAssertEqual(reopened.project?.name, "Renamed")
        XCTAssertEqual(reopened.project?.id, id)
        await reopened.flush()
    }
}
