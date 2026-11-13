import SwiftUI
import MakeLORACore

struct ServerClipEditor: View {
    @ObservedObject var store: ServerDatasetStore
    let project: ServerDataset
    let video: ServerDatasetVideo
    let initial: ServerDatasetClip
    var body: some View {
        if let url = video.previewURL {
            VideoClipEditorWorkspace(
                name: video.name, duration: video.duration ?? initial.end,
                width: video.width ?? 16, height: video.height ?? 9,
                media: VideoEditorMedia(url: url, thumbnails: video.thumbnails),
                clips: project.clips.filter { $0.videoID == video.id }.map(\.editorClip), selectedID: initial.id,
                newClipAt: project.clips.contains(where: { $0.id == initial.id }) ? nil : initial.start,
                refresh: {
                    try await store.open(project.id)
                    guard let fresh = store.project?.videos.first(where: { $0.id == video.id }), let url = fresh.previewURL else { throw URLError(.resourceUnavailable) }
                    return VideoEditorMedia(url: url, thumbnails: fresh.thumbnails)
                },
                save: { baseline, edited in try await store.saveSourceClips(projectID: project.id, videoID: video.id, baseline: baseline, edited: edited) }
            )
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "video.slash", description: Text("Reopen the dataset to refresh its preview."))
        }
    }
}
