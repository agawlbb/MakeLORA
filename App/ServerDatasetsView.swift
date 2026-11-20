import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import MakeLORACore

struct ServerDatasetsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = ServerDatasetStore()
    @State private var create = false
    @State private var name = ""
    @State private var model = "wan"
    @State private var settings = false
    var body: some View {
        NavigationStack {
            Group {
                if pairing.credential == nil {
                    ContentUnavailableView { Label("Connect your server", systemImage: "server.rack") }
                    description: { Text("Pair this device in Server settings.") }
                    actions: { Button("Server settings") { settings = true } }
                } else if let project = store.project {
                    ServerDatasetWorkspace(store: store, project: project).id(project.id)
                } else {
                    List {
                        Section("Datasets") {
                            Button { name = ""; create = true } label: {
                                Label("New dataset", systemImage: "plus").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            .disabled(store.connection?.connected != true)
                            if store.projects.isEmpty {
                                Text("Create a dataset, then import images or videos.").foregroundStyle(.secondary)
                            }
                            ForEach(store.projects) { p in
                                Button { Task { await store.perform { try await store.open(p.id) } } } label: {
                                    HStack { Label(p.name, systemImage: "rectangle.stack"); Spacer(); Text("\(p.count)").foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Section {
                            if store.connection?.connected == true {
                                Label("FileBeans connected", systemImage: "checkmark.circle")
                            } else if let connection = store.connection {
                                Label(connection.configured ? "FileBeans unavailable" : "Connect FileBeans", systemImage: "externaldrive")
                                if let url = store.managementURL { Link("FileBeans settings", destination: url) }
                            } else {
                                ProgressView("Checking FileBeans…")
                            }
                        }
                    }.refreshable { await store.perform { try await store.refresh() } }
                }
            }
            .navigationTitle(store.project?.name ?? "Datasets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.project != nil { Button("Datasets", systemImage: "chevron.left") { store.project = nil; Task { await store.perform { try await store.refresh() } } } }
                    else { Button("Server", systemImage: "server.rack") { settings = true } }
                }
                ToolbarItem(placement: .topBarTrailing) { if store.project == nil && pairing.credential != nil && !store.projects.isEmpty { Button("New dataset", systemImage: "plus") { name = ""; create = true }.disabled(store.connection?.connected != true) } }
            }
            .disabled(store.busy)
            .overlay { if store.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .sheet(isPresented: $settings) { ServerView() }
        .sheet(isPresented: $create) {
            NavigationStack {
                Form {
                    TextField("Dataset name", text: $name)
                    Picker("Model", selection: $model) { Text("Wan 2.1 Image-to-Video").tag("wan"); Text("Qwen Image Edit 2509").tag("qwen") }
                }.navigationTitle("New dataset").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { create = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { create = false; Task { await store.perform { try await store.create(name, model: model) } } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }
        .alert("Datasets", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Retry") { Task { await store.perform { if let id = store.project?.id { try await store.open(id) } else { try await store.refresh() } } } }
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: pairing.credential?.token) { store.configure(pairing.credential); if pairing.credential != nil { await store.perform { try await store.refresh() } } }
        .onChange(of: phase) { _, value in if value == .active, pairing.credential != nil { Task { await store.perform { try await store.refresh() } } } }
    }
}

private enum DatasetImportRoute: String, Identifiable { case filebeans, files, photos, camera, output, relink; var id: String { rawValue } }
private struct ServerDatasetWorkspace: View {
    @ObservedObject var store: ServerDatasetStore
    let project: ServerDataset
    @Environment(\.scenePhase) private var phase
    @State private var browser: DatasetImportRoute?
    @State private var importRoute: DatasetImportRoute?
    @State private var renderAfterSelection = false
    @State private var destination: FileBeansLocation?
    @State private var lastDestination: FileBeansLocation?
    @State private var files = false
    @State private var photos = false
    @State private var camera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var area = "Sources"
    @State private var viewing: ServerDatasetVideo?
    @State private var removing: ServerDatasetVideo?
    @State private var choosingClip = false
    @State private var editing: ServerDatasetClip?
    @State private var pair: ServerDatasetClip?
    @State private var relinking: ServerDatasetVideo?
    @State private var deleting = false
    @State private var rename = false
    @State private var name = ""
    @State private var uploading = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var pending: [URL] = []
    @State private var pendingScope: VideoFileSelection?
    @State private var uploadError: String?
    @State private var retryName = ""
    @State private var transferred: [FileBeansLocation] = []
    private var workspaceList: some View {
        List {
            Picker("Workspace", selection: $area) {
                Text("Sources").tag("Sources")
                Text(project.model == "wan" ? "Clips" : "Pairs").tag("Edits")
                Text("Export").tag("Export")
            }.pickerStyle(.segmented).listRowBackground(Color.clear)
            if project.model == "wan" {
                Section("Dataset clip length") {
                    Stepper(value: Binding(get: { project.clipDuration ?? 5 }, set: { value in
                        Task { await store.perform { try await store.save(project.clips, revision: project.revision, clipDuration: value) } }
                    }), in: 0.5...60, step: 0.5) {
                        Text("\(project.clipDuration ?? 5, specifier: "%.1f") seconds")
                    }.disabled(project.processing)
                    Text("Applies to every clip. Sources must be at least this long.").font(.caption)
                }
            }
            if area == "Sources" {
            Section {
                Menu {
                    Button("From FileBeans", systemImage: "externaldrive") { browser = .filebeans }
                    Button("From Files", systemImage: "folder") { chooseDestination(.files) }
                    Button("From Photos", systemImage: "photo.on.rectangle") { chooseDestination(.photos) }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("Camera", systemImage: "camera") { chooseDestination(.camera) } }
                } label: { Label("Import sources", systemImage: "square.and.arrow.down") }
            }
            Section("Sources") {
                ForEach(project.videos) { video in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { Task { await store.perform { viewing = try await store.source(video.id) } } } label: {
                            Label(video.name, systemImage: project.model == "wan" ? "video" : "photo")
                        }
                        Text(video.source + " / " + video.path).font(.caption).foregroundStyle(.secondary)
                        Button("Relink source") { relinking = video; browser = .relink }
                    }.swipeActions { Button("Remove source", role: .destructive) { removing = video } }
                }
                if project.videos.isEmpty { Text("Add sources to this dataset.").foregroundStyle(.secondary) }
            }
            }
            if area == "Edits" {
                Section {
                    if project.model == "wan" {
                        Button("New clip", systemImage: "plus") { choosingClip = true }.disabled(project.videos.isEmpty)
                    } else {
                        Button("New image pair", systemImage: "plus") { pair = ServerDatasetClip(id: ServerDatasetClip.identifier()) }.disabled(project.videos.isEmpty)
                    }
                }
            Section(project.model == "wan" ? "Clips" : "Image pairs") {
                ForEach(project.clips) { clip in
                    Button { if project.model == "wan" { openClip(clip) } else { pair = clip }; store.noteActivity() } label: {
                        HStack {
                            if project.model == "qwen", let source = project.videos.first(where: { $0.id == clip.control }), let url = source.originalURL {
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "photo") }.frame(width: 70, height: 50)
                            } else { Image(systemName: "video").frame(width: 70, height: 50) }
                            VStack(alignment: .leading) {
                                if project.model == "wan" { Text(String(format: "%.2f–%.2f s", clip.start, clip.end)) } else { Text("Image pair") }
                                Text(clip.caption.isEmpty ? "Needs caption" : clip.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.swipeActions { Button("Remove", role: .destructive) { Task { await store.perform { try await store.save(project.clips.filter { $0.id != clip.id }, revision: project.revision) } } } }
                }.onMove { from, to in
                    var clips = project.clips; clips.move(fromOffsets: from, toOffset: to)
                    Task { await store.perform { try await store.save(clips, revision: project.revision) } }
                }
            }
            }
            if area == "Export" {
            Section("Output") {
                Button("Export dataset", systemImage: "folder.badge.plus") {
                    if let location = project.destination { Task { await store.perform { try await store.export(to: location) } } } else { renderAfterSelection = true; browser = .output }
                }.disabled(project.clips.isEmpty || ["queued", "processing"].contains(project.exportStatus))
                Button("Choose output folder") { renderAfterSelection = false; browser = .output }
                if ["queued", "processing"].contains(project.exportStatus) {
                    Label(project.exportStatus.capitalized, systemImage: "clock")
                    Button("Cancel export", role: .destructive) { Task { await store.perform { try await store.cancelExport() } } }
                }
                if let error = project.exportError { Text(error).foregroundStyle(.red).font(.caption) }
                if let folder = project.exportFolder { Label(folder, systemImage: "checkmark.circle").textSelection(.enabled) }
            }
            }
        }
        .disabled(uploading)
        .refreshable { await store.perform { try await store.open(project.id) } }
        .toolbar {
            if area == "Edits" { EditButton() }
            Menu {
                Button("Rename") { name = project.name; rename = true }
                Button("Delete dataset", role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var importPresentation: some View {
        workspaceList
        .sheet(item: $browser) { route in
            FileBeansBrowser(store: store, foldersOnly: route != .filebeans && route != .relink, single: route == .relink,
                             initial: route == .output ? project.destination : lastDestination) { locations in
                guard let location = locations.first else { return }
                switch route {
                case .filebeans: Task { await store.perform { try await store.importSources(locations) } }
                case .relink: if let relinking { Task { await store.perform { try await store.relink(relinking.id, to: location) } } }
                case .output: Task { await store.perform { try await store.setDestination(location); if renderAfterSelection { try await store.export(to: location) } } }
                default:
                    destination = location; lastDestination = location
                    // Let the destination sheet finish dismissing before presenting a picker.
                    Task { try? await Task.sleep(for: .milliseconds(400)); presentImport() }
                }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: project.model == "wan" ? [.movie, .plainText] : [.image, .plainText], allowsMultipleSelection: true) { result in
            do { let urls = try result.get(); pendingScope = VideoFileSelection(urls: urls); pending = urls.sorted { $0.pathExtension.lowercased() == "txt" && $1.pathExtension.lowercased() != "txt" }; startUpload() }
            catch { store.error = error.localizedDescription }
        }
        .photosPicker(isPresented: $photos, selection: $photoItems, maxSelectionCount: 100, matching: project.model == "wan" ? .videos : .images, preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            uploadTask = Task {
                uploading = true
                do {
                    for item in items {
                        try Task.checkCancellation()
                        if project.model == "wan" {
                            guard let movie = try await item.loadTransferable(type: ImportedVideo.self) else { throw URLError(.cannotDecodeContentData) }; pending.append(movie.url)
                        } else {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw URLError(.cannotDecodeContentData) }
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORA-upload-\(UUID()).\(item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")")
                            try data.write(to: url, options: .atomic); pending.append(url)
                        }
                    }
                    photoItems = []; await uploadPending()
                } catch { store.error = error.localizedDescription; cleanupPending(); uploading = false }
            }
        }
    }

    private var editorPresentation: some View {
        importPresentation
        .fullScreenCover(isPresented: $camera) { DatasetCamera(video: project.model == "wan") { url in if let url { pending = [url]; startUpload() } } }
        .fullScreenCover(item: $editing) { clip in
            if let video = project.videos.first(where: { $0.id == clip.videoID }) { ServerClipEditor(store: store, project: project, video: video, initial: clip) }
        }
        .fullScreenCover(item: $viewing) { source in DatasetSourceViewer(store: store, source: source, video: project.model == "wan") }
        .confirmationDialog("Choose a source", isPresented: $choosingClip, titleVisibility: .visible) {
            ForEach(project.videos) { source in
                Button(source.name) { openClip(ServerDatasetClip(id: ServerDatasetClip.identifier(), videoID: source.id)) }
            }
        }
        .confirmationDialog("Remove source and its edits?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove source", role: .destructive) { if let source = removing { Task { await store.perform { try await store.removeVideo(source.id) } } }; removing = nil }
        }
        .sheet(item: $pair) { value in ServerImagePairEditor(store: store, project: project, initial: value) }
    }

    private var dialogPresentation: some View {
        editorPresentation
        .alert("Rename dataset", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Save") { Task { await store.perform { try await store.save(project.clips, name: name, revision: project.revision) } } }; Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete dataset?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete dataset", role: .destructive) { Task { await store.perform { try await store.delete() } } }
        }
        .alert("Upload needs attention", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
            TextField("Filename", text: $retryName)
            Button("Retry") { uploadError = nil; startUpload() }
            Button("Choose folder") { uploadError = nil; importRoute = nil; browser = .files }
            Button("Cancel", role: .cancel) { uploadError = nil; cleanupPending() }
        } message: { Text(uploadError ?? "") }
    }

    var body: some View {
        dialogPresentation
        .overlay { if uploading {
            VStack(spacing: 12) { ProgressView("Uploading to FileBeans…"); Button("Cancel") { uploadTask?.cancel() } }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } }
        .task(id: project.id) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if phase == .active && !store.busy && editing == nil && pair == nil && browser == nil && !uploading { await store.poll(project.id) }
            }
        }
        .onDisappear { uploadTask?.cancel(); cleanupPending() }
    }
    private func openClip(_ clip: ServerDatasetClip) {
        Task { await store.perform {
            let source = try await store.source(clip.videoID, inspect: true)
            var draft = clip
            if draft.end <= draft.start { draft.end = source.duration ?? 0; draft.caption = source.caption ?? "" }
            editing = draft
        } }
    }
    private func chooseDestination(_ route: DatasetImportRoute) { importRoute = route; browser = route }
    private func presentImport() {
        if !pending.isEmpty { startUpload(); return }
        switch importRoute { case .photos: photos = true; case .camera: camera = true; default: files = true }
    }
    private func startUpload() { uploadTask = Task { await uploadPending() } }
    private func uploadPending() async {
        guard let destination else { return }; uploading = true; defer { uploading = false }
        do {
            while let url = pending.first {
                try Task.checkCancellation()
                let filename = retryName.isEmpty ? url.lastPathComponent : retryName
                guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else { throw URLError(.badURL) }
                let staged = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORA-stage-\(UUID())")
                defer { try? FileManager.default.removeItem(at: staged) }
                try await CoordinatedFileImport.copy(source: url, destination: staged, maximumBytes: 2 * 1024 * 1024 * 1024)
                let location = destination.appending(filename)
                try await store.upload(staged, to: location)
                if url.pathExtension.lowercased() != "txt" { transferred.append(location) }
                removeTemporary(url); pending.removeFirst(); retryName = ""
            }
            if !transferred.isEmpty { try await store.importSources(transferred); transferred = [] }
            pendingScope = nil
        } catch is CancellationError { cleanupPending() }
        catch { retryName = pending.first?.lastPathComponent ?? ""; uploadError = error.localizedDescription }
    }
    private func removeTemporary(_ url: URL) {
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: url) }
    }
    private func cleanupPending() { pending.forEach(removeTemporary); pending = []; pendingScope = nil; transferred = []; retryName = "" }
}

struct FileBeansBrowser: View {
    @ObservedObject var store: ServerDatasetStore
    let foldersOnly: Bool
    var single = false
    var initial: FileBeansLocation?
    let selected: ([FileBeansLocation]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scopes: [FileBeansScope] = []
    @State private var location: FileBeansLocation?
    @State private var entries: [FileBeansEntry] = []
    @State private var selection: Set<FileBeansLocation> = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        NavigationStack {
            List {
                if let location {
                    Button("Sources", systemImage: "externaldrive") { self.location = nil }
                    Text(location.source + " / " + location.path).font(.caption)
                    if location.path != "/" { Button("Parent folder", systemImage: "chevron.up") { self.location = FileBeansLocation(source: location.source, path: (location.path as NSString).deletingLastPathComponent) } }
                    ForEach(entries.filter { $0.isFolder || !foldersOnly && $0.type.hasPrefix(store.project?.model == "wan" ? "video/" : "image/") }) { entry in
                        let item = FileBeansLocation(source: location.source, path: entry.path)
                        Button {
                            if entry.isFolder { self.location = item }
                            else if selection.contains(item) { selection.remove(item) }
                            else { if single { selection = [] }; if selection.count < 100 { selection.insert(item) } }
                        } label: { Label(entry.name, systemImage: entry.isFolder ? "folder" : selection.contains(item) ? "checkmark.circle.fill" : "circle") }
                    }
                } else {
                    ForEach(scopes) { scope in Button(scope.name, systemImage: "externaldrive") { location = FileBeansLocation(source: scope.name, path: "/") } }
                }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red); Button("Retry") { Task { await load() } } }
            }.navigationTitle(foldersOnly ? "Storage folder" : "FileBeans")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(foldersOnly ? "Use this folder" : "Select \(selection.count)") {
                        let values = foldersOnly ? location.map { [$0] } ?? [] : selection.sorted { $0.path < $1.path }
                        dismiss(); selected(values)
                    }.disabled(loading || error != nil || (foldersOnly ? location == nil : selection.isEmpty))
                }
            }.task { location = initial; await load() }
            .task(id: location) { await load() }
        }
    }
    private func load() async {
        let requested = location; loading = true; error = nil
        defer { if location == requested { loading = false } }
        do {
            if let requested { let reply = try await store.browse(requested); if location == requested { entries = reply.children ?? [] } }
            else { scopes = try await store.scopes() }
        } catch is CancellationError { }
        catch { if location == requested { self.error = error.localizedDescription } }
    }
}

private struct DatasetCamera: UIViewControllerRepresentable {
    let video: Bool
    let completed: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        picker.videoQuality = .typeHigh; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: DatasetCamera
        init(_ parent: DatasetCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss(); parent.completed(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORA-camera-\(UUID()).\(parent.video ? "mov" : "jpg")")
                if let movie = info[.mediaURL] as? URL { try FileManager.default.copyItem(at: movie, to: url) }
                else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { try data.write(to: url) }
                else { throw URLError(.cannotDecodeContentData) }
                parent.dismiss(); parent.completed(url)
            } catch { parent.dismiss(); parent.completed(nil) }
        }
    }
}

private struct DatasetSourceViewer: View {
    @ObservedObject var store: ServerDatasetStore
    let source: ServerDatasetVideo
    let video: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playbackError: String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Group {
                if video {
                    VideoPlayer(player: player)
                        .overlay { if let playbackError { Text(playbackError).padding().background(.regularMaterial) } }
                }
                else if let url = source.originalURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { Text("Unable to open this original. Check FileBeans access and try again.") }
                        else { ProgressView() }
                    }
                }
            }
            .navigationTitle(source.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                if video, let url = source.originalURL {
                    let item = AVPlayerItem(url: url)
                    item.preferredForwardBufferDuration = 1
                    player = AVPlayer(playerItem: item)
                }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    if phase == .active, player?.timeControlStatus == .playing { store.noteActivity() }
                    if player?.currentItem?.status == .failed {
                        playbackError = "Unable to play this original on this device."
                        do { _ = try await store.source(source.id) }
                        catch { playbackError = error.localizedDescription }
                        return
                    }
                }
            }
            .onDisappear {
                player?.pause(); player?.currentItem?.asset.cancelLoading()
                player?.replaceCurrentItem(with: nil); player = nil
            }
            .simultaneousGesture(TapGesture().onEnded { store.noteActivity() })
        }
    }
}
