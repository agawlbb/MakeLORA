import Foundation

public struct Crop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = Crop()
    public var clamped: Crop {
        let w = min(1, max(0.01, width.isFinite ? width : 1))
        let h = min(1, max(0.01, height.isFinite ? height : 1))
        return Crop(x: min(1-w, max(0, x.isFinite ? x : 0)), y: min(1-h, max(0, y.isFinite ? y : 0)), width: w, height: h)
    }
}

public struct LibraryPhoto: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var name: String
    public init(id: UUID = UUID(), filename: String, name: String) { self.id = id; self.filename = filename; self.name = name }
}

public struct ImagePair: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var control: UUID
    public var target: UUID
    public var caption: String
    public var controlCrop: Crop
    public var targetCrop: Crop
    public init(id: Int, control: UUID, target: UUID, caption: String = "", controlCrop: Crop = .full, targetCrop: Crop = .full) {
        self.id = id; self.control = control; self.target = target; self.caption = caption
        self.controlCrop = controlCrop; self.targetCrop = targetCrop
    }
    public mutating func swap() {
        (control, target) = (target, control)
        (controlCrop, targetCrop) = (targetCrop, controlCrop)
    }
}

public enum DatasetModel: String, Codable, CaseIterable, Sendable {
    case qwenImageEdit2509 = "qwen-image-edit-2509"
    case wan21I2V14B = "wan-2.1-i2v-14b-480p"
    public var title: String { self == .qwenImageEdit2509 ? "Qwen Image Edit 2509" : "Wan 2.1 Image-to-Video 14B" }
}

public struct LibraryVideo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var name: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public init(id: UUID = UUID(), filename: String, name: String, duration: Double, width: Int, height: Int) {
        self.id = id; self.filename = filename; self.name = name; self.duration = duration; self.width = width; self.height = height
    }
}

public struct VideoSample: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var video: UUID
    public var caption: String
    public var start: Double
    public var end: Double
    public var crop: Crop
    public init(id: Int, video: UUID, caption: String = "", start: Double = 0, end: Double, crop: Crop = .full) {
        self.id = id; self.video = video; self.caption = caption; self.start = start; self.end = end; self.crop = crop
    }
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(width) * crop.width, h = Double(height) * crop.height
        let scale = 480 / min(w, h)
        return (max(2, Int((w * scale / 2).rounded()) * 2), max(2, Int((h * scale / 2).rounded()) * 2))
    }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var formatVersion = 1
    public var id: UUID
    public var name: String
    public var photos: [LibraryPhoto] = []
    public var pairs: [ImagePair] = []
    public var nextPairID = 1
    public var model: DatasetModel = .qwenImageEdit2509
    public var videos: [LibraryVideo] = []
    public var samples: [VideoSample] = []
    public var nextSampleID = 1
    public var sampleCount: Int { model == .qwenImageEdit2509 ? pairs.count : samples.count }
    public var datasetFilenames: [String] {
        if model == .wan21I2V14B { return samples.sorted { $0.id < $1.id }.flatMap { ["\($0.id).mp4", "\($0.id).txt"] } }
        return pairs.sorted { $0.id < $1.id }.flatMap { ["control/\($0.id).jpg", "target/\($0.id).jpg", "target/\($0.id).txt"] }
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, id, name, photos, pairs, nextPairID, model, videos, samples, nextSampleID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        photos = try c.decode([LibraryPhoto].self, forKey: .photos); pairs = try c.decode([ImagePair].self, forKey: .pairs)
        nextPairID = try c.decode(Int.self, forKey: .nextPairID)
        model = try c.decodeIfPresent(DatasetModel.self, forKey: .model) ?? .qwenImageEdit2509
        videos = try c.decodeIfPresent([LibraryVideo].self, forKey: .videos) ?? []
        samples = try c.decodeIfPresent([VideoSample].self, forKey: .samples) ?? []
        nextSampleID = try c.decodeIfPresent(Int.self, forKey: .nextSampleID) ?? 1
    }
    @discardableResult public mutating func addSample(video: LibraryVideo, caption: String = "") -> Int {
        let id = nextSampleID
        samples.append(VideoSample(id: id, video: video.id, caption: caption, end: video.duration)); nextSampleID += 1
        return id
    }
    public init(id: UUID = UUID(), name: String, model: DatasetModel = .qwenImageEdit2509) { self.id = id; self.name = name; self.model = model; self.formatVersion = model == .wan21I2V14B ? 2 : 1 }
    @discardableResult public mutating func addPair(control: UUID, target: UUID) -> Int {
        let id = nextPairID
        pairs.append(ImagePair(id: id, control: control, target: target))
        nextPairID += 1
        return id
    }
    public func validate() throws {
        guard (formatVersion == 1 && model == .qwenImageEdit2509) || formatVersion == 2 else { throw ProjectError.invalid("This project uses an unsupported version.") }
        let videoIDs = Set(videos.map(\.id))
        guard videoIDs.count == videos.count, Set(samples.map(\.id)).count == samples.count,
              nextSampleID > (samples.map(\.id).max() ?? 0),
              (model == .wan21I2V14B ? photos.isEmpty && pairs.isEmpty : videos.isEmpty && samples.isEmpty),
              videos.allSatisfy({ !$0.filename.isEmpty && $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.contains("..") && $0.duration.isFinite && $0.duration > 0 && $0.width > 0 && $0.height > 0 && $0.width <= 30000 && $0.height <= 30000 }),
              samples.allSatisfy({ sample in
                  guard let source = videos.first(where: { $0.id == sample.video }) else { return false }
                  return sample.id > 0 && sample.start.isFinite && sample.end.isFinite && sample.start >= 0 && sample.end > sample.start && sample.end <= source.duration && sample.crop == sample.crop.clamped
              }) else { throw ProjectError.invalid("The project has invalid video references, trim or crop settings. Originals have been preserved.") }
        let ids = Set(photos.map(\.id))
        guard ids.count == photos.count, Set(pairs.map(\.id)).count == pairs.count,
              nextPairID > (pairs.map(\.id).max() ?? 0),
              photos.allSatisfy({ !$0.filename.isEmpty && $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.contains("..") }),
              pairs.allSatisfy({ $0.id > 0 && ids.contains($0.control) && ids.contains($0.target) && $0.controlCrop == $0.controlCrop.clamped && $0.targetCrop == $0.targetCrop.clamped }) else {
            throw ProjectError.invalid("The project has invalid image references or crop settings. Restore a valid project copy; the existing files have been preserved.")
        }
    }
}

public enum ProjectError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
