import SwiftUI
import MakeLORACore

struct GenerationVideoEdit: Codable, Equatable {
    var source: String
    var path: String
    var revision: String
    var vault: String
    var start: Double
    var end: Double
    var crop: Crop?
    var location: FileBeansLocation { FileBeansLocation(source: source, path: path) }
    var body: [String: Any] { get throws { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any] } }
}
struct GenerationVideoSource: Decodable, Identifiable {
    let source: String
    let path: String
    let revision: String
    let vault: String
    let name: String
    let duration: Double
    let width: Int
    let height: Int
    let previewURL: URL
    var id: String { source + ":" + path + ":" + revision }
    var initialEdit: GenerationVideoEdit { GenerationVideoEdit(source: source, path: path, revision: revision, vault: vault, start: 0, end: min(duration, 60), crop: nil) }
}
struct GenerationInputVideoEditor: View {
    let source: GenerationVideoSource
    let initial: GenerationVideoEdit?
    let refresh: () async throws -> GenerationVideoSource
    let saved: (GenerationVideoEdit) -> Void
    var body: some View {
        let edit = initial.flatMap { $0.source == source.source && $0.path == source.path && $0.revision == source.revision ? $0 : nil } ?? source.initialEdit
        VideoClipEditorWorkspace(
            name: source.name, duration: source.duration, width: source.width, height: source.height,
            media: VideoEditorMedia(url: source.previewURL),
            clips: [VideoEditingClip(id: "generation-input", start: edit.start, end: edit.end, crop: edit.crop ?? .full)],
            selectedID: "generation-input", singleClip: true,
            refresh: { VideoEditorMedia(url: try await refresh().previewURL) }, forceSave: true,
            save: { _, clips in
                guard clips.count == 1, let clip = clips.first, clip.end - clip.start >= 0.1, clip.end - clip.start <= 60.001 else { throw ProjectError.invalid("Choose one clip between 0.1 and 60 seconds.") }
                var result = edit
                result.start = clip.start; result.end = clip.end; result.crop = clip.crop
                saved(result)
                return VideoEditSaveResult(clips: clips)
            }
        )
    }
}
