import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MakeLORACore

private let accent = Color(red: 0.70, green: 0.91, blue: 0.43)

struct RootView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.scenePhase) private var phase
    @State private var serverSettings = false
    @State private var newProject = false
    @State private var projectName = ""
    var body: some View {
        Group {
            if let project = store.project { WorkspaceView(projectID: project.id).id(project.id) }
            else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("A starting point.\nA different possibility.").font(.system(size: 42, weight: .semibold, design: .rounded))
                                Text("Build paired-image datasets, one transformation at a time.").foregroundStyle(.secondary)
                            }.padding(.vertical, 20)
                            if store.projects.isEmpty {
                                ContentUnavailableView("Your first dataset starts here", systemImage: "rectangle.stack.badge.plus", description: Text("Create a project, import photos, then pair a control image with a target."))
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 18) {
                                ForEach(store.projects) { summary in
                                    Button { store.open(summary) } label: {
                                        VStack(alignment: .leading, spacing: 24) {
                                            Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(accent)
                                            Text(summary.name).font(.title2.bold()).lineLimit(2)
                                            Text("\(summary.count) pairs · On this device").font(.subheadline).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, minHeight: 160, alignment: .leading).padding(24)
                                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(20)
                    }
                    .navigationTitle("MakeLORA")
                    .toolbar { Button("Server", systemImage: "server.rack") { serverSettings = true }; Button("New project", systemImage: "plus") { projectName = ""; newProject = true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black) }
                }
            }
        }
        .tint(accent)
        .sheet(isPresented: $serverSettings) { ServerView() }
        .disabled(store.busy)
        .overlay { if store.busy { ProgressView(store.status).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert("New project", isPresented: $newProject) {
            TextField("Project name", text: $projectName)
            Button("Create") { store.create(name: projectName) }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .alert("MakeLORA needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: phase) { _, value in
            if value != .active { Task { await store.flush() } }
        }
    }
}

struct WorkspaceView: View {
    let projectID: UUID
    @EnvironmentObject private var store: ProjectStore
    @State private var selectedPair: Int?
    @State private var tab = 0
    @State private var newPair = false
    @State private var importFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var deleteProject = false
    @State private var rename = false
    @State private var name = ""
    @State private var share: ExportItem?
    private var project: Project { store.project ?? Project(name: "") }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900 && geometry.size.width > geometry.size.height
            NavigationStack {
                HStack(spacing: 0) {
                    workspaceLibrary.frame(width: wide ? 280 : nil)
                    if wide {
                        Divider()
                        if let id = selectedPair, project.pairs.contains(where: { $0.id == id }) {
                            PairEditor(pairID: id).id(id).frame(maxWidth: .infinity)
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 56)).foregroundStyle(accent)
                                Text("Every edit starts with a pair").font(.title.bold())
                                Text("Choose the starting image and the desired result,\nthen describe what changed.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                                Button("Create a pair", systemImage: "plus") { newPair = true }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(project.photos.isEmpty)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .navigationDestination(isPresented: Binding(
                    get: { !wide && selectedPair != nil },
                    set: { if !$0 && !wide { selectedPair = nil } }
                )) {
                    if let id = selectedPair {
                        PairEditor(pairID: id).navigationTitle("Pair \(id)")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Projects", systemImage: "chevron.left") { store.close() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Button("Retry", systemImage: "arrow.clockwise") { store.retry() }.labelStyle(.iconOnly)
                            Button("Export dataset", systemImage: "square.and.arrow.up") { Task { if let url = await store.export() { share = ExportItem(url: url) } } }.labelStyle(.iconOnly).buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(project.pairs.isEmpty)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $newPair) { NewPairView { id in selectedPair = id; tab = 0 } }
        .sheet(item: $share, onDismiss: { cleanupExports() }) { item in ShareSheet(url: item.url) }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            Task {
                do {
                    let urls = try result.get()
                    store.setImporting(true)
                    for url in urls {
                        let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                            await store.importPhotos([(data, url.lastPathComponent)])
                            store.setImporting(true)
                        } catch { store.report("Read \(url.lastPathComponent)", error) }
                    }
                    store.setImporting(false); store.retry()
                } catch { store.report("Import from Files", error) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                store.setImporting(true)
                for (index, item) in items.enumerated() {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ProjectError.invalid("Photos did not supply image data. Download the original from iCloud and import again.") }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "image"
                        await store.importPhotos([(data, "Photo \(project.photos.count + 1)-\(index + 1).\(ext)")])
                        store.setImporting(true)
                    } catch { store.report("Read photo from Photos", error) }
                }
                photoItems = []; store.setImporting(false); store.retry()
            }
        }
        .alert("Rename project", isPresented: $rename) {
            TextField("Project name", text: $name)
            Button("Save") { store.update { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete \(project.name) and all its originals and pairs? This cannot be undone.", isPresented: $deleteProject, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) { store.deleteProject() }
        }
        .onAppear { cleanupExports() }
        .onChange(of: project.pairs.map(\.id)) { _, ids in
            if let selectedPair, !ids.contains(selectedPair) { self.selectedPair = nil }
        }
    }
    private var workspaceLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("WORKSPACE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Rename project", systemImage: "pencil") { name = project.name; rename = true }
                    Button("Delete project…", systemImage: "trash", role: .destructive) { deleteProject = true }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("Project actions")
            }
            Picker("Workspace section", selection: $tab) { Text("Pairs (\(project.pairs.count))").tag(0); Text("Photos (\(project.photos.count))").tag(1) }.pickerStyle(.segmented)
            if tab == 0 {
                Button { newPair = true } label: { Label("New pair", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(project.photos.isEmpty)
                if project.pairs.isEmpty { Text("Import photos, then create your first pair.").foregroundStyle(.secondary).padding(.vertical) }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(project.pairs) { pair in
                            Button { selectedPair = pair.id } label: {
                                HStack(spacing: 8) {
                                    PhotoThumbnail(photoID: pair.control, crop: pair.controlCrop, maximum: 200).frame(width: 54, height: 54).clipped()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Pair \(pair.id)").fontWeight(.semibold)
                                        Text(pair.caption.isEmpty ? "Add a transformation caption" : pair.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).background(selectedPair == pair.id ? accent.opacity(0.15) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(project.photos) { photo in
                            VStack(alignment: .leading, spacing: 5) {
                                PhotoThumbnail(photoID: photo.id, maximum: 250).frame(height: 105).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(photo.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 100, matching: .images, preferredItemEncoding: .current) { Label("From Photos", systemImage: "photo.on.rectangle") }
                Button("From Files", systemImage: "folder") { importFiles = true }
            } label: { Label("Import photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            Text("HEIC, JPEG & PNG originals\nDataset images always export as JPG.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity).background(.white.opacity(0.025))
    }
    private func cleanupExports() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("MakeLORA-") { try? fm.removeItem(at: url) }
    }
}

struct ExportItem: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
