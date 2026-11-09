import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import MakeLORACore

/// Serial image work stays off the UI thread. Originals are never rewritten.
actor ImageEngine {
    private var revisions: [UUID: Int] = [:]
    private let fm = FileManager.default

    func importPhoto(data: Data, name: String, directory: URL) throws -> LibraryPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30000, height <= 30000, width * height <= 100_000_000,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else {
            throw ProjectError.invalid("Cannot import \(name). Choose a readable HEIC, JPEG or PNG image up to 100 megapixels and 30,000 pixels per side.")
        }
        let id = UUID()
        let ext = UTType(type as String)?.preferredFilenameExtension ?? "image"
        let filename = "\(id.uuidString).\(ext)"
        let originals = directory.appendingPathComponent("originals", isDirectory: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        try data.write(to: originals.appendingPathComponent(filename), options: .atomic)
        return LibraryPhoto(id: id, filename: filename, name: name)
    }

    func thumbnail(url: URL, crop: Crop, maximum: Int = 900) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum
              ] as CFDictionary), let cropped = image.cropping(to: rectangle(crop, image: image)) else { return nil }
        return UIImage(cgImage: cropped)
    }

    func synchronize(_ project: Project, directory: URL, revision: Int) throws {
        if revision < revisions[project.id, default: -1] { return }
        revisions[project.id] = revision
        try project.validate()
        let dataset = directory.appendingPathComponent("dataset", isDirectory: true)
        for folder in ["control", "target"] { try fm.createDirectory(at: dataset.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let marker = directory.appendingPathComponent("generated.json")
        let previous = (try? JSONDecoder().decode([ImagePair].self, from: Data(contentsOf: marker))) ?? []
        // Invalidate the cache before changing outputs. A failed/terminated write
        // must never leave an old marker claiming that partially replaced files match.
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        for pair in project.pairs {
            try autoreleasepool {
                let old = previous.first { $0.id == pair.id }
                for isControl in [true, false] {
                    let photoID = isControl ? pair.control : pair.target
                    let crop = isControl ? pair.controlCrop : pair.targetCrop
                    let path = dataset.appendingPathComponent("\(isControl ? "control" : "target")/\(pair.id).jpg")
                    let unchanged = isControl ? old?.control == photoID && old?.controlCrop == crop : old?.target == photoID && old?.targetCrop == crop
                    if !unchanged || !fm.fileExists(atPath: path.path) {
                        guard let photo = project.photos.first(where: { $0.id == photoID }) else { throw ProjectError.invalid("Pair \(pair.id) is missing a photo. Replace that photo and try again.") }
                        try autoreleasepool { try renderJPEG(source: directory.appendingPathComponent("originals/\(photo.filename)"), crop: crop, destination: path) }
                    }
                }
                try Data(pair.caption.utf8).write(to: dataset.appendingPathComponent("target/\(pair.id).txt"), options: .atomic)
            }
        }
        let expectedControl = Set(project.pairs.map { "\($0.id).jpg" })
        let expectedTarget = expectedControl.union(project.pairs.map { "\($0.id).txt" })
        for (folder, expected) in [("control", expectedControl), ("target", expectedTarget)] {
            let url = dataset.appendingPathComponent(folder)
            for file in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where !expected.contains(file.lastPathComponent) { try fm.removeItem(at: file) }
        }
        try JSONEncoder().encode(project.pairs).write(to: marker, options: .atomic)
    }

    func export(_ project: Project, directory: URL, revision: Int) throws -> URL {
        try synchronize(project, directory: directory, revision: revision)
        guard !project.pairs.isEmpty else { throw ProjectError.invalid("Create at least one pair before exporting.") }
        let output = fm.temporaryDirectory.appendingPathComponent("MakeLORA-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let safeName = project.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let archive = output.appendingPathComponent("\(String(safeName.prefix(80))).zip")
        let files = project.pairs.sorted { $0.id < $1.id }.flatMap { pair in
            ["control/\(pair.id).jpg", "target/\(pair.id).jpg", "target/\(pair.id).txt"].map { (name: $0, url: directory.appendingPathComponent("dataset/\($0)")) }
        }
        try DatasetZIP.write(files: files, to: archive)
        return archive
    }

    private func rectangle(_ crop: Crop, image: CGImage) -> CGRect {
        let c = crop.clamped
        let x = min(image.width-1, Int((c.x * Double(image.width)).rounded(.down)))
        let y = min(image.height-1, Int((c.y * Double(image.height)).rounded(.down)))
        let width = max(1, min(image.width-x, Int((c.width * Double(image.width)).rounded(.down))))
        let height = max(1, min(image.height-y, Int((c.height * Double(image.height)).rounded(.down))))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func renderJPEG(source url: URL, crop: Crop, destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), let image = oriented.cropping(to: rectangle(crop, image: oriented)) else {
            throw ProjectError.invalid("Cannot generate a JPG from \(url.lastPathComponent). Replace the source photo and retry generation.")
        }
        // Flatten alpha onto white and encode fresh pixels, never copying EXIF/GPS.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let data = UIGraphicsImageRenderer(size: CGSize(width: image.width, height: image.height), format: format).jpegData(withCompressionQuality: 0.95) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        try data.write(to: destination, options: .atomic)
    }
}
