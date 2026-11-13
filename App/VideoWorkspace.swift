import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import AVKit
import MakeLORACore

struct ImportedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORAVideoImport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return ImportedVideo(url: url)
        }
    }
}

struct VideoWorkspaceView: View {
    let projectID: UUID
    @EnvironmentObject private var store: ProjectStore
    @State private var selected: LocalVideoEditorSelection?
    @State private var files = false
    @State private var pendingFiles: VideoFileSelection?
    @State private var photos: [PhotosPickerItem] = []
    @State private var share: ExportItem?
    @State private var exportURL: URL?
    @State private var delete = false
    @State private var rename = false
    @State private var name = ""
    private var project: Project { store.project ?? Project(name: "", model: .wan21I2V14B) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(project.model.title).font(.headline)
                    Text("Trim and caption your clips. Export matching MP4 and TXT files in one folder.").foregroundStyle(.secondary)
                    PhotosPicker("Import from Photos", selection: $photos, maxSelectionCount: 100, matching: .videos, preferredItemEncoding: .current)
                    Button("Import videos and captions from Files") { files = true }
                }
                Section("Clips · \(project.samples.count)") {
                    ForEach(project.samples) { sample in
                        if let video = project.videos.first(where: { $0.id == sample.video }), let url = store.original(video) {
                            Button { selected = LocalVideoEditorSelection(videoID: video.id, clipID: sample.id) } label: {
                                HStack {
                                    VideoFrame(url: url, time: sample.start).frame(width: 90, height: 60).clipped()
                                    VStack(alignment: .leading) {
                                        Text("Clip \(sample.id) · \(video.name)").lineLimit(1)
                                        Text(sample.caption.isEmpty ? "Add a caption" : sample.caption).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                        Text("\(sample.end - sample.start, specifier: "%.2f") seconds").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }.onDelete { offsets in store.update { $0.samples.remove(atOffsets: offsets) } }
                }
                Section("Source videos") {
                    ForEach(project.videos) { video in
                        Button { selected = LocalVideoEditorSelection(videoID: video.id, clipID: project.samples.first(where: { $0.video == video.id })?.id) } label: {
                            Label(video.name, systemImage: "film.stack")
                        }
                    }
                }
                Section { Text(store.status).font(.caption); Text("480p · aspect ratio preserved · H.264 MP4 · no audio. Originals remain untouched.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Projects", systemImage: "chevron.left") { store.close() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename project") { name = project.name; rename = true }
                        Button("Retry conversion") { store.retry() }
                        Button("Delete project", role: .destructive) { delete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button("Export dataset", systemImage: "square.and.arrow.up") { Task { if let url = await store.export() { exportURL = url; share = ExportItem(url: url) } } }.disabled(project.samples.isEmpty)
                }
            }
        }
        .fullScreenCover(item: $selected) { selection in
            if let video = project.videos.first(where: { $0.id == selection.videoID }), let url = store.original(video) {
                VideoClipEditorWorkspace(name: video.name, duration: video.duration, width: video.width, height: video.height,
                    media: VideoEditorMedia(url: url), clips: project.samples.filter { $0.video == video.id }.map(VideoEditingClip.init),
                    selectedID: selection.clipID.map(String.init),
                    save: { baseline, edited in try store.saveVideoEdits(projectID: projectID, videoID: video.id, baseline: baseline, edited: edited) })
            }
        }
        .sheet(item: $share, onDismiss: cleanupShare) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $files, onDismiss: importSelectedFiles) {
            VideoFilesPicker(onSelection: { urls in
                pendingFiles = VideoFileSelection(urls: urls)
                files = false
            }, onCancel: { pendingFiles = nil; files = false })
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                store.beginImport()
                defer { photos = []; store.setImporting(false) }
                for item in items {
                    if store.cancelRequested { break }
                    do {
                        guard let movie = try await item.loadTransferable(type: ImportedVideo.self) else { throw ProjectError.invalid("Download the original video from iCloud and try again.") }
                        defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
                        await store.importVideos([movie.url])
                        store.setImporting(true)
                    } catch { store.report("Import video", error) }
                }
            }
        }
        .alert("Rename project", isPresented: $rename) {
            TextField("Project name", text: $name)
            Button("Save") { store.update { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete this project and all its original videos?", isPresented: $delete, titleVisibility: .visible) { Button("Delete project", role: .destructive) { store.deleteProject() } }
        .onChange(of: project.videos.map(\.id)) { _, ids in if let selected, !ids.contains(selected.videoID) { self.selected = nil } }
    }
    private func importSelectedFiles() {
        guard let selection = pendingFiles else { return }
        pendingFiles = nil
        Task {
            // Keep security-scoped access alive until coordinated staging finishes.
            await store.importVideoFiles(selection.urls)
            withExtendedLifetime(selection) { }
        }
    }
    private func cleanupShare() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }
}

struct VideoFrame: View {
    let url: URL
    var time: Double = 0
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "video.slash") }
            else { ProgressView() }
        }
        .task(id: "\(url.absoluteString)-\(time)") {
            image = nil; failed = false
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 600, height: 600)
            do {
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                try Task.checkCancellation(); image = UIImage(cgImage: result.image)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct LocalVideoEditorSelection: Identifiable {
    let videoID: UUID
    let clipID: Int?
    var id: UUID { videoID }
}
