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

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var formatVersion = 1
    public var id: UUID
    public var name: String
    public var photos: [LibraryPhoto] = []
    public var pairs: [ImagePair] = []
    public var nextPairID = 1
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    @discardableResult public mutating func addPair(control: UUID, target: UUID) -> Int {
        let id = nextPairID
        pairs.append(ImagePair(id: id, control: control, target: target))
        nextPairID += 1
        return id
    }
    public func validate() throws {
        guard formatVersion == 1 else { throw ProjectError.invalid("This project uses an unsupported version.") }
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
