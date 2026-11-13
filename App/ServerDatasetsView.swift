import SwiftUI
import AVKit

struct ServerDatasetsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = ServerDatasetStore()
    @State private var create = false
    @State private var name = ""
    @State private var settings = false
    var body: some View {
        NavigationStack {
            Group {
                if pairing.credential == nil {
                    ContentUnavailableView {
                        Label("Connect your server", systemImage: "server.rack")
                    } description: {
                        Text("Pair this device in Server settings to use Google Drive and server datasets.")
                    } actions: { Button("Server settings") { settings = true } }
                } else if let project = store.project {
                    ServerDatasetWorkspace(store: store, project: project)
                } else {
                    List {
                        Section {
                            Text("Original videos and exported datasets stay on your server. This device streams previews for editing.")
                            if let url = store.managementURL {
                                Link(store.connection?.connected == true ? "Manage Google Drive connection" : "Connect Google Drive on server", destination: url)
                            }
                        }
                        Section("Server datasets · Wan 2.1 I2V 14B") {
                            ForEach(store.projects) { p in
                                Button { Task { await store.perform { try await store.open(p.id) } } } label: {
                                    HStack { Label(p.name, systemImage: "externaldrive"); Spacer(); Text("\(p.count) clips").foregroundStyle(.secondary) }
                                }
                            }
                            Button("New server dataset", systemImage: "plus") { name = ""; create = true }
                        }
                        if store.projects.isEmpty { Text("Create a server dataset, then select videos from Google Drive.").foregroundStyle(.secondary) }
                    }
                    .refreshable { await store.perform { try await store.refresh() } }
                }
            }
            .navigationTitle(store.project?.name ?? "Server datasets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.project != nil {
                        Button("Datasets", systemImage: "chevron.left") { store.project = nil; Task { await store.perform { try await store.refresh() } } }
                    } else { Button("Done") { dismiss() } }
                }
            }
            .disabled(store.busy)
            .overlay { if store.busy { ProgressView("Saving on server…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .sheet(isPresented: $settings) { ServerView() }
        .alert("New server dataset", isPresented: $create) {
            TextField("Dataset name", text: $name)
            Button("Create") { Task { await store.perform { try await store.create(name) } } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .alert("Server datasets", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: pairing.credential?.token) {
            store.configure(pairing.credential)
            if pairing.credential != nil { await store.perform { try await store.refresh() } }
        }
        .onChange(of: phase) { _, value in
            if value == .active, pairing.credential != nil { Task { await store.perform { try await store.refresh() } } }
        }
    }
}

private struct ServerDatasetWorkspace: View {
    @ObservedObject var store: ServerDatasetStore
    let project: ServerDataset
    @State private var drive = false
    @State private var editing: ServerDatasetClip?
    @State private var delete = false
    @State private var removeSource: ServerDatasetVideo?
    @State private var rename = false
    @State private var name = ""
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section {
                Button("Import from Google Drive", systemImage: "cloud") { drive = true }
                if let url = store.managementURL { Link("Manage Drive connection", destination: url) }
                if store.connection?.workerReady == false {
                    Label("The dataset worker is offline. Imports and exports will wait until it is started on the server.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Text("Select private Drive videos directly. Matching UTF-8 TXT captions in the same folder are imported automatically.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Clips") {
                ForEach(project.clips) { clip in
                    if let video = project.videos.first(where: { $0.id == clip.videoID }) {
                        Button { editing = clip } label: {
                            HStack {
                                if let url = video.thumbnails?.first {
                                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(width: 80, height: 50)
                                }
                                VStack(alignment: .leading) {
                                    Text(video.name).lineLimit(1)
                                    Text(String(format: "%.2f–%.2f s · %@", clip.start, clip.end, clip.caption.isEmpty ? "Needs caption" : clip.caption)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await store.perform { try await store.save(project.clips.filter { $0.id != clip.id }, revision: project.revision) } } }
                        }
                    }
                }
                if project.clips.isEmpty { Text("Import videos to start trimming and captioning.").foregroundStyle(.secondary) }
            }
            Section("Source videos") {
                ForEach(project.videos) { video in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(video.name); Spacer(); if ["queued", "processing"].contains(video.status) { ProgressView() }; Text(video.status.capitalized).font(.caption) }
                        if let error = video.error {
                            Text(error).foregroundStyle(.red).font(.caption)
                            Button("Retry import") { Task { await store.perform { try await store.importVideos([video.driveID]) } } }
                        }
                        if video.status == "ready", let duration = video.duration {
                            Button("Add another clip") { editing = ServerDatasetClip(id: ServerDatasetClip.identifier(), videoID: video.id, start: 0, end: duration, caption: "", crop: nil) }
                        }
                    }
                    .swipeActions { Button("Remove source", role: .destructive) { removeSource = video } }
                }
            }
            Section("480p dataset") {
                Button("Render dataset on server", systemImage: "film.stack") { Task { await store.perform { try await store.export() } } }.disabled(project.clips.isEmpty || ["queued", "processing"].contains(project.exportStatus))
                if ["queued", "processing"].contains(project.exportStatus) {
                    Label("\(project.exportStatus.capitalized) · you can close the app", systemImage: "clock")
                }
                if let error = project.exportError { Text(error).font(.caption).foregroundStyle(.red) }
                if let url = project.exportURL {
                    Text("Ready on server. ZIP contains numbered MP4/TXT pairs. The shorter side is 480 pixels, preserving the cropped aspect ratio.").font(.footnote)
                    ShareLink("Share download link", item: url)
                    Text("The private download link expires after one hour and grants access to this ZIP. Share it only with your training server or someone you trust.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await store.perform { try await store.open(project.id) } }
        .toolbar {
            Menu {
                Button("Rename") { name = project.name; rename = true }
                Button("Delete dataset…", role: .destructive) { delete = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .sheet(isPresented: $drive) { DriveBrowserView(store: store) }
        .sheet(item: $editing) { clip in
            if let video = project.videos.first(where: { $0.id == clip.videoID }) {
                ServerClipEditor(store: store, project: project, video: video, initial: clip)
            }
        }
        .alert("Rename dataset", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Save") { Task { await store.perform { try await store.save(project.clips, name: name, revision: project.revision) } } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete this dataset and its server copies? Drive originals are kept.", isPresented: $delete, titleVisibility: .visible) {
            Button("Delete dataset", role: .destructive) { Task { await store.perform { try await store.delete() } } }
        }
        .confirmationDialog("Remove this server source and all its clips? The Drive original is kept.", isPresented: Binding(get: { removeSource != nil }, set: { if !$0 { removeSource = nil } }), titleVisibility: .visible) {
            if let video = removeSource {
                Button("Remove source and clips", role: .destructive) { Task { await store.perform { try await store.removeVideo(video.id) } }; removeSource = nil }
            }
        }
        .task(id: project.id) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if phase == .active && !store.busy && editing == nil && !drive { await store.poll(project.id) }
            }
        }
    }
}

private struct DriveFolder: Equatable { let id: String; let name: String }
private struct DriveBrowserView: View {
    @ObservedObject var store: ServerDatasetStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = [DriveFolder(id: "root", name: "My Drive")]
    @State private var files: [DriveFile] = []
    @State private var page: String?
    @State private var selection: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    private var folder: DriveFolder { path.last! }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Location", selection: Binding(get: { path.first?.id ?? "root" }, set: { path = [DriveFolder(id: $0, name: $0 == "root" ? "My Drive" : "Shared with me")] })) {
                        Text("My Drive").tag("root"); Text("Shared with me").tag("shared")
                    }
                    if path.count > 1 { Button("Back to \(path[path.count - 2].name)", systemImage: "chevron.left") { path.removeLast() } }
                }
                Section(folder.name) {
                    ForEach(files) { file in
                        Button {
                            if file.isFolder { path.append(DriveFolder(id: file.id, name: file.name)) }
                            else if selection.contains(file.id) { selection.remove(file.id) }
                            else if selection.count < 100 { selection.insert(file.id) }
                        } label: {
                            HStack { Image(systemName: file.isFolder ? "folder" : (selection.contains(file.id) ? "checkmark.circle.fill" : "circle")); Text(file.name); Spacer(); if let size = file.size, let bytes = Int64(size) { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                    if page != nil { Button("Load more") { Task { await load(more: true) } }.disabled(loading) }
                    if loading { ProgressView("Reading Drive…") }
                    if !loading && files.isEmpty { Text("No videos or folders here.").foregroundStyle(.secondary) }
                }
                if let error { Section { Text(error).foregroundStyle(.red); if let url = store.managementURL { Link("Manage Google Drive connection", destination: url) }; Button("Retry") { Task { await load() } } } }
            }
            .navigationTitle("Google Drive")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selection.count)") {
                        Task {
                            await store.perform {
                                try await store.importVideos(selection)
                                dismiss()
                            }
                            if let message = store.error { error = message; store.error = nil }
                        }
                    }.disabled(selection.isEmpty || store.busy)
                }
            }
            .disabled(store.busy)
            .task(id: folder.id) { await load() }
        }
    }
    private func load(more: Bool = false) async {
        let id = folder.id; loading = true; error = nil
        if !more { files = []; page = nil }
        defer { if folder.id == id { loading = false } }
        do {
            let reply = try await store.browse(id, page: more ? page : nil)
            guard folder.id == id else { return }
            let existing = Set(files.map(\.id)); files += reply.files.filter { !existing.contains($0.id) }; page = reply.nextPageToken
        } catch is CancellationError { }
        catch { if folder.id == id { self.error = error.localizedDescription } }
    }
}
