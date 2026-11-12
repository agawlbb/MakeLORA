import Foundation
import AVFoundation
import CoreImage
import UIKit
import MakeLORACore

/// Imports and conversions are serialized without holding video frames in memory.
actor VideoEngine {
    private var tail: Task<Void, Never>?
    private var revisions: [UUID: Int] = [:]

    func importVideo(url: URL, name: String, directory: URL) async throws -> LibraryVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalid("Choose a readable video.") }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard duration.isFinite, duration > 0, oriented.width.isFinite, oriented.height.isFinite, oriented.width > 0, oriented.height > 0, oriented.width <= 30000, oriented.height <= 30000 else { throw ProjectError.invalid("This video has no readable frames.") }
        let id = UUID(), filename = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let originals = directory.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let destination = originals.appendingPathComponent(filename)
        do {
            try Task.checkCancellation()
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ProjectError.invalid("Cannot store the original video. Check device storage.") }
            let input = try FileHandle(forReadingFrom: url), output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); try output.write(contentsOf: data)
            }
            return LibraryVideo(id: id, filename: filename, name: name, duration: duration, width: Int(oriented.width.rounded()), height: Int(oriented.height.rounded()))
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    func waitUntilIdle() async { await tail?.value }

    func synchronize(_ project: Project, directory: URL, revision: Int, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let previous = tail
        let operation = Task {
            await previous?.value
            try Task.checkCancellation()
            try await self.generate(project, directory: directory, revision: revision, progress: progress)
        }
        tail = Task { _ = await operation.result }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }

    private func generate(_ project: Project, directory: URL, revision: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard revision >= revisions[project.id, default: -1] else { return }
        revisions[project.id] = revision
        try project.validate()
        let fm = FileManager.default, dataset = directory.appendingPathComponent("dataset", isDirectory: true)
        try fm.createDirectory(at: dataset, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("generated-videos.json")
        let previous = (try? JSONDecoder().decode([VideoSample].self, from: Data(contentsOf: marker))) ?? []
        // Removing the marker makes interruption recoverable, even between video and caption writes.
        try? fm.removeItem(at: marker)
        for (index, sample) in project.samples.enumerated() {
            try Task.checkCancellation()
            guard let video = project.videos.first(where: { $0.id == sample.video }) else { throw ProjectError.invalid("Video \(sample.id) is missing its original.") }
            let destination = dataset.appendingPathComponent("\(sample.id).mp4")
            let old = previous.first { $0.id == sample.id }
            if old?.video != sample.video || old?.start != sample.start || old?.end != sample.end || old?.crop != sample.crop || !fm.fileExists(atPath: destination.path) {
                let temporary = dataset.appendingPathComponent(".\(UUID().uuidString).mp4")
                defer { try? fm.removeItem(at: temporary) }
                try await render(source: directory.appendingPathComponent("originals/\(video.filename)"), sample: sample, video: video, destination: temporary) { fraction in
                    progress((Double(index) + fraction) / Double(max(1, project.samples.count)))
                }
                try Task.checkCancellation()
                if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
                else { try fm.moveItem(at: temporary, to: destination) }
            }
            try Data(sample.caption.utf8).write(to: dataset.appendingPathComponent("\(sample.id).txt"), options: .atomic)
            progress(Double(index + 1) / Double(max(1, project.samples.count)))
        }
        try Task.checkCancellation()
        let expected = Set(project.samples.flatMap { ["\($0.id).mp4", "\($0.id).txt"] })
        for file in try fm.contentsOfDirectory(at: dataset, includingPropertiesForKeys: nil) where !expected.contains(file.lastPathComponent) { try fm.removeItem(at: file) }
        try JSONEncoder().encode(project.samples).write(to: marker, options: .atomic)
    }

    func export(_ project: Project, directory: URL, revision: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard !project.samples.isEmpty else { throw ProjectError.invalid("Import at least one video before exporting.") }
        try await synchronize(project, directory: directory, revision: revision, progress: progress)
        try Task.checkCancellation()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let safe = String(project.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(80))
        let archive = output.appendingPathComponent(safe + ".zip")
        let files = project.datasetFilenames.map { (name: $0, url: directory.appendingPathComponent("dataset/\($0)")) }
        try DatasetZIP.write(files: files, to: archive)
        return archive
    }

    private func render(source: URL, sample: VideoSample, video: LibraryVideo, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProjectError.invalid("The original video is unavailable.") }
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let displayBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
        // Track transforms use top-left coordinates; Core Image uses bottom-left.
        let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: naturalSize.height)
            .concatenating(preferredTransform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -displayBounds.minX, ty: displayBounds.maxY))
        let dimensions = sample.outputSize(width: video.width, height: video.height)
        guard dimensions.width <= 8192, dimensions.height <= 8192 else { throw ProjectError.invalid("This crop is too narrow to encode. Choose a wider crop.") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: sample.start, preferredTimescale: 60000), end: CMTime(seconds: sample.end, preferredTimescale: 60000))
        // Decode to SDR BGRA. The decoder tone maps HDR before fresh Rec.709 encoding.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectError.invalid("Cannot decode this video. Try exporting it as MP4 first.") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: dimensions.width, AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(4_000_000, dimensions.width * dimensions.height * 12), AVVideoAllowFrameReorderingKey: false],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: dimensions.width, kCVPixelBufferHeightKey as String: dimensions.height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw ProjectError.invalid("Cannot encode these video dimensions.") }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? ProjectError.invalid("Cannot start video conversion.") }
        writer.startSession(atSourceTime: .zero)
        var complete = false
        defer { reader.cancelReading(); if !complete { writer.cancelWriting() } }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var first: CMTime?, count = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            // Only retain frames whose presentation time is inside the requested range.
            guard pts.seconds >= sample.start, pts.seconds < sample.end else { continue }
            if first == nil { first = pts }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? ProjectError.invalid("Video encoder stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            try autoreleasepool {
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(buffer), let pool = adaptor.pixelBufferPool else { throw ProjectError.invalid("Cannot read a video frame.") }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { throw ProjectError.invalid("Not enough memory for video conversion.") }
                var image = CIImage(cvPixelBuffer: sourceBuffer).transformed(by: transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let crop = CGRect(x: sample.crop.x * image.extent.width, y: (1 - sample.crop.y - sample.crop.height) * image.extent.height, width: sample.crop.width * image.extent.width, height: sample.crop.height * image.extent.height)
                image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                image = image.transformed(by: CGAffineTransform(scaleX: Double(dimensions.width) / crop.width, y: Double(dimensions.height) / crop.height))
                context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height), colorSpace: colorSpace)
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTimeSubtract(pts, first!)) else { throw writer.error ?? ProjectError.invalid("Cannot write a video frame.") }
            }
            count += 1
            progress(min(1, (pts.seconds - sample.start) / (sample.end - sample.start)))
        }
        guard reader.status == .completed, count > 0 else { throw reader.error ?? ProjectError.invalid("This trim contains no readable video frames. Extend the trim range.") }
        writer.endSession(atSourceTime: CMTime(seconds: sample.end - first!.seconds, preferredTimescale: 60000))
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? ProjectError.invalid("Video conversion did not finish.") }
        complete = true
    }
}
