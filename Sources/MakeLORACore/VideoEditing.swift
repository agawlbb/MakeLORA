import Foundation

public struct VideoEditingClip: Identifiable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var caption: String
    public var crop: Crop
    public init(id: String, start: Double, end: Double, caption: String = "", crop: Crop = .full) {
        self.id = id; self.start = start; self.end = end; self.caption = caption; self.crop = crop
    }
    public init(_ sample: VideoSample) { self.init(id: String(sample.id), start: sample.start, end: sample.end, caption: sample.caption, crop: sample.crop) }
    public static func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

public struct VideoEditSaveResult: Sendable {
    public var clips: [VideoEditingClip]
    public var idMapping: [String: String]
    public init(clips: [VideoEditingClip], idMapping: [String: String] = [:]) { self.clips = clips; self.idMapping = idMapping }
}

public struct VideoEditingSession: Sendable {
    public let duration: Double
    public private(set) var baseline: [VideoEditingClip]
    public private(set) var clips: [VideoEditingClip]
    public var selectedID: String?
    public var selected: VideoEditingClip? { clips.first { $0.id == selectedID } }
    public var hasChanges: Bool { clips != baseline }
    public var minimumLength: Double { min(0.1, duration) }
    public init(duration: Double, clips: [VideoEditingClip], selectedID: String?) {
        self.duration = duration; self.baseline = clips; self.clips = clips
        self.selectedID = selectedID.flatMap { id in clips.contains { $0.id == id } ? id : nil } ?? clips.first?.id
    }
    public mutating func edit(_ work: (inout VideoEditingClip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == selectedID }) else { return }
        work(&clips[index])
    }
    public mutating func setStart(_ time: Double) {
        guard time.isFinite, let selected else { return }
        let value = min(max(0, time), max(0, selected.end - minimumLength))
        edit { $0.start = value }
    }
    public mutating func setEnd(_ time: Double) {
        guard time.isFinite, let selected else { return }
        let value = min(duration, max(selected.start + minimumLength, time))
        edit { $0.end = value }
    }
    @discardableResult public mutating func add(at time: Double, fallbackToBeginning: Bool = true) -> Bool {
        guard time.isFinite, duration > 0 else { return false }
        var start = max(0, min(duration, time))
        if duration - start < minimumLength {
            guard fallbackToBeginning else { return false }; start = 0
        }
        let clip = VideoEditingClip(id: VideoEditingClip.identifier(), start: start, end: min(duration, start + 5))
        clips.append(clip); selectedID = clip.id; return true
    }
    public mutating func duplicate() {
        guard var copy = selected else { return }
        copy.id = VideoEditingClip.identifier(); clips.append(copy); selectedID = copy.id
    }
    public mutating func removeSelected() {
        guard let index = clips.firstIndex(where: { $0.id == selectedID }) else { return }
        clips.remove(at: index); selectedID = clips.isEmpty ? nil : clips[min(index, clips.count - 1)].id
    }
    public mutating func accept(_ result: VideoEditSaveResult) {
        selectedID = selectedID.map { result.idMapping[$0] ?? $0 }
        baseline = result.clips; clips = result.clips
        if !clips.contains(where: { $0.id == selectedID }) { selectedID = clips.first?.id }
    }
}

public enum VideoClipChanges {
    /// Merge only edits/deletions, retaining unrelated clips and concurrent changes.
    public static func merge(baseline: [VideoEditingClip], edited: [VideoEditingClip], current: [VideoEditingClip]) throws -> [VideoEditingClip] {
        guard Set(baseline.map(\.id)).count == baseline.count, Set(edited.map(\.id)).count == edited.count, Set(current.map(\.id)).count == current.count else { throw ProjectError.invalid("Duplicate clip identifiers.") }
        let before = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: edited.map { ($0.id, $0) })
        let latest = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let removed = Set(before.keys).subtracting(after.keys)
        let changed = edited.filter { before[$0.id] != $0 }
        for id in removed.union(changed.map(\.id)) {
            guard latest[id] == before[id] else { throw ProjectError.invalid("A clip you edited changed elsewhere. Your draft is preserved; reopen the editor to load the latest saved clips.") }
        }
        var result = current.filter { !removed.contains($0.id) }.map { clip in changed.first(where: { $0.id == clip.id }) ?? clip }
        result += changed.filter { latest[$0.id] == nil }
        return result
    }
}

public enum VideoCropCorner: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
public enum VideoCropShape: String, CaseIterable, Sendable {
    case free = "Free", original = "Original", square = "Square", landscape = "16:9", portrait = "9:16"
    public func aspect(source: Double) -> Double? {
        switch self { case .free: return nil; case .original: return source; case .square: return 1; case .landscape: return 16.0/9; case .portrait: return 9.0/16 }
    }
}
public enum VideoCropGeometry {
    public static func fitted(aspect: Double, width: Double, height: Double) -> (width: Double, height: Double) {
        guard aspect.isFinite, aspect > 0, width.isFinite, height.isFinite, width > 0, height > 0 else { return (0, 0) }
        let w = min(width, height * aspect); return (w, w/aspect)
    }
    public static func preset(_ shape: VideoCropShape, sourceAspect: Double, around crop: Crop) -> Crop {
        guard let aspect = shape.aspect(source: sourceAspect), sourceAspect > 0 else { return crop }
        let ratio = aspect/sourceAspect, w = min(1, ratio), h = min(1, 1/ratio)
        return Crop(x: min(1-w, max(0, crop.x + crop.width/2 - w/2)), y: min(1-h, max(0, crop.y + crop.height/2 - h/2)), width: w, height: h)
    }
    public static func move(_ crop: Crop, dx: Double, dy: Double) -> Crop {
        guard dx.isFinite, dy.isFinite else { return crop }
        var next = crop; next.x = min(1-crop.width, max(0, crop.x+dx)); next.y = min(1-crop.height, max(0, crop.y+dy)); return next
    }
    public static func resize(_ crop: Crop, corner: VideoCropCorner, dx: Double, dy: Double, normalizedAspect: Double?) -> Crop {
        guard dx.isFinite, dy.isFinite else { return crop }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let ax = left ? crop.x+crop.width : crop.x, ay = top ? crop.y+crop.height : crop.y
        let maxW = left ? ax : 1-ax, maxH = top ? ay : 1-ay
        var w = crop.width + (left ? -dx : dx), h = crop.height + (top ? -dy : dy)
        if let ratio = normalizedAspect, ratio.isFinite, ratio > 0 {
            let desired = abs(dx) >= abs(dy)*ratio ? w : h*ratio
            let upper = min(maxW, maxH*ratio), lower = min(upper, max(0.05, 0.05*ratio))
            w = min(upper, max(lower, desired)); h = w/ratio
        } else { w = min(maxW, max(min(0.05, maxW), w)); h = min(maxH, max(min(0.05, maxH), h)) }
        return Crop(x: left ? ax-w : ax, y: top ? ay-h : ay, width: w, height: h).clamped
    }
}

extension Project {
    public mutating func saveVideoEdits(video: UUID, baseline: [VideoEditingClip], edited: [VideoEditingClip]) throws -> VideoEditSaveResult {
        guard let source = videos.first(where: { $0.id == video }) else { throw ProjectError.invalid("The source video no longer exists.") }
        let current = samples.filter { $0.video == video }.map(VideoEditingClip.init)
        let merged = try VideoClipChanges.merge(baseline: baseline, edited: edited, current: current)
        var mapping: [String: String] = [:], result: [VideoSample] = []
        var nextID = nextSampleID
        for clip in merged {
            let id: Int
            if let existing = samples.first(where: { String($0.id) == clip.id && $0.video == video }) { id = existing.id }
            else { id = nextID; nextID += 1; mapping[clip.id] = String(id) }
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.end > clip.start, clip.end <= source.duration else { throw ProjectError.invalid("Choose a trim inside the source video.") }
            result.append(VideoSample(id: id, video: video, caption: clip.caption, start: clip.start, end: clip.end, crop: clip.crop))
        }
        var updated = self
        let replacements = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let priorIDs = Set(samples.map(\.id))
        updated.samples = samples.compactMap { sample in sample.video == video ? replacements[sample.id] : sample }
        updated.samples += result.filter { !priorIDs.contains($0.id) }
        updated.nextSampleID = nextID
        try updated.validate(); self = updated
        return VideoEditSaveResult(clips: result.map(VideoEditingClip.init), idMapping: mapping)
    }
}
