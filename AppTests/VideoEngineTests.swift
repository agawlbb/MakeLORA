import XCTest
import AVFoundation
import CoreImage
import MakeLORACore
@testable import MakeLORA

final class VideoEngineTests: XCTestCase {
    private func fixture(at url: URL, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        // Variable presentation intervals intentionally include a gap before the trim start.
        for (index, time) in [0.0, 0.1, 0.3, 0.4, 0.6, 0.7, 0.9].enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            let blue = CIImage(color: CIColor(red: 0, green: CGFloat(index) / 20, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
            let red = CIImage(color: CIColor(red: 1, green: CGFloat(index) / 20, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 90))
            context.render(red.composited(over: blue), to: pixel)
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60000)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 60000)); input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testTrimOrientationCadenceAndFlatExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await fixture(at: source, rotated: true)
        let engine = VideoEngine()
        let video = try await engine.importVideo(url: source, name: "source.mov", directory: directory)
        XCTAssertEqual(video.width, 90); XCTAssertEqual(video.height, 160)
        var project = Project(name: "Video fixture", model: .wan21I2V14B)
        project.videos = [video]; project.addSample(video: video, caption: "A moving color")
        project.samples[0].start = 0.15; project.samples[0].end = 0.8
        let archive = try await engine.export(project, directory: directory, revision: 1, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let dataset = directory.appendingPathComponent("dataset")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dataset.path)), ["1.mp4", "1.txt"])
        XCTAssertEqual(try String(contentsOf: dataset.appendingPathComponent("1.txt"), encoding: .utf8), "A moving color")
        let output = AVURLAsset(url: dataset.appendingPathComponent("1.mp4"))
        let tracks = try await output.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 480); XCTAssertEqual(size.height, 854)
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        // Decode before inspecting presentation timing. Compressed buffers include
        // decode-order and container bookkeeping samples, not just displayed frames.
        let reader = try AVAssetReader(asset: output)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(samples); XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = []
        while let buffer = samples.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(buffer) != nil { timestamps.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) }
        }
        XCTAssertEqual(reader.status, .completed)
        // The frame already visible at 0.15 starts the clip. Later source frames
        // at 0.3, 0.4, 0.6 and 0.7 retain their offsets from the chosen trim start.
        let expectedTimes = [0.0, 0.15, 0.25, 0.45, 0.55]
        XCTAssertEqual(timestamps.count, expectedTimes.count, "Decoded presentation times: \(timestamps)")
        for (actual, expected) in zip(timestamps, expectedTimes) { XCTAssertEqual(actual, expected, accuracy: 0.003, "Decoded presentation times: \(timestamps)") }
        let outputDuration = try await output.load(.duration)
        XCTAssertEqual(outputDuration.seconds, 0.65, accuracy: 0.003)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: directory.appendingPathComponent("originals/\(video.filename)")))
        let generator = AVAssetImageGenerator(asset: output)
        let firstFrame = try await generator.image(at: .zero).image
        let frameImage = CIImage(cgImage: firstFrame)
        func pixel(y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { memory in
                CIContext().render(frameImage, toBitmap: memory.baseAddress!, rowBytes: 4, bounds: CGRect(x: 200, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes
        }
        let top = pixel(y: firstFrame.height - 10), bottom = pixel(y: 10)
        XCTAssertGreaterThan(top[0], top[2], "Clockwise source rotation keeps the red source-left half at the top")
        XCTAssertGreaterThan(bottom[2], bottom[0])
        project.samples[0].crop = Crop(width: 0.5, height: 1)
        try await engine.synchronize(project, directory: directory, revision: 2)
        let cropped = AVURLAsset(url: dataset.appendingPathComponent("1.mp4"))
        let croppedTracks = try await cropped.loadTracks(withMediaType: .video)
        let croppedTrack = try XCTUnwrap(croppedTracks.first)
        let croppedSize = try await croppedTrack.load(.naturalSize)
        XCTAssertEqual(croppedSize.width, 480); XCTAssertEqual(croppedSize.height, 1706)
        let modification = try dataset.appendingPathComponent("1.mp4").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        project.samples[0].caption = "Changed caption only"
        try await engine.synchronize(project, directory: directory, revision: 3)
        XCTAssertEqual(try dataset.appendingPathComponent("1.mp4").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modification, "Caption edits must not reencode video")
        XCTAssertEqual(try String(contentsOf: dataset.appendingPathComponent("1.txt"), encoding: .utf8), "Changed caption only")
    }

    func testCanceledGenerationDoesNotPublishOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov"); try await fixture(at: source)
        let engine = VideoEngine()
        let video = try await engine.importVideo(url: source, name: "source.mov", directory: directory)
        var project = Project(name: "Cancel", model: .wan21I2V14B)
        project.videos = [video]; project.addSample(video: video)
        let snapshot = project
        let task = Task { try await engine.synchronize(snapshot, directory: directory, revision: 1) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dataset/1.mp4").path))
        try await engine.synchronize(project, directory: directory, revision: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dataset/1.mp4").path))
    }
    @MainActor func testFilesBatchImportsVideoAndMatchingCaptionAndClearsBusyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("motion.mov"), caption = directory.appendingPathComponent("motion.txt")
        try await fixture(at: source)
        try Data("Move slowly".utf8).write(to: caption)
        let store = ProjectStore(root: directory.appendingPathComponent("projects"))
        store.create(name: "Files import", model: .wan21I2V14B)
        defer { store.cancelWork() }
        await store.importVideoFiles([source, caption])
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.project?.samples.first?.caption, "Move slowly")
        let video = try XCTUnwrap(store.project?.videos.first)
        let original = try XCTUnwrap(store.original(video))
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: source))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path).contains { $0.hasPrefix(".incoming-") })
    }

    @MainActor func testFailedFilesImportClearsBusyAndPreservesExistingProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(root: directory.appendingPathComponent("projects"))
        store.create(name: "Failed import", model: .wan21I2V14B)
        defer { store.cancelWork() }
        await store.importVideoFiles([directory.appendingPathComponent("unavailable.mov")])
        XCTAssertFalse(store.busy)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.project?.videos.isEmpty == true)
        XCTAssertTrue(store.project?.samples.isEmpty == true)
    }

}
