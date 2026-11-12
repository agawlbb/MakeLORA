import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct GenerationView: View {
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var phase
    @State private var serverSettings = false
    @State private var selectedModel: GenerationModel?
    @State private var selectedOutput: GenerationOutput?
    var body: some View {
        NavigationStack {
            List {
                Section("Custom LoRA weights") {
                    if pairing.credential == nil {
                        ContentUnavailableView("Connect a server", systemImage: "server.rack", description: Text("Pair your server to browse its custom LoRA weights and generate images."))
                        Button("Connect server") { serverSettings = true }
                    } else if store.models.isEmpty {
                        Text("No weights loaded. Pull to refresh or add weights on your server.").foregroundStyle(.secondary)
                    }
                    ForEach(store.models) { model in
                        Button { selectedModel = model } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName).font(.headline)
                                Text(model.baseModel ?? "Base model not specified").font(.subheadline).foregroundStyle(.secondary)
                            }.foregroundStyle(.primary)
                        }
                    }
                }
                Section("Output gallery · \(store.outputs.count + store.galleryJobs.count)") {
                    if store.outputs.isEmpty && store.galleryJobs.isEmpty { Text("Images are stored on your server and shared with all paired devices.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                        ForEach(store.galleryJobs) { job in
                            GenerationProgressTile(job: job)
                        }
                        ForEach(store.outputs) { output in
                            Button { selectedOutput = output } label: {
                                VStack(alignment: .leading) {
                                    ServerGenerationImage(output: output).frame(height: 150).clipped()
                                    Text(output.model).font(.caption).lineLimit(1)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("View generated image, \(output.model)")
                        }
                    }
                }
            }
            .navigationTitle("Generation")
            .toolbar { Button("Server", systemImage: "server.rack") { serverSettings = true } }
            .refreshable { await store.load(pairing.credential) }
        }
        .task(id: "\(pairing.credential?.deviceID ?? "")-\(phase)") {
            guard phase == .active else { return }
            await store.load(pairing.credential)
            await store.watchGallery()
        }
        .sheet(isPresented: $serverSettings) { ServerView() }
        .sheet(item: $selectedModel) { GenerationComposer(model: $0) }
        .fullScreenCover(item: $selectedOutput) { GenerationDetail(output: $0) }
        .onChange(of: pairing.credential?.deviceID) { _, _ in selectedOutput = nil; selectedModel = nil }
        .alert("Generation needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
private struct GenerationProgressTile: View {
    let job: GenerationJob
    @EnvironmentObject private var store: GenerationStore
    @State private var confirmRemove = false
    @State private var confirmStopRetries = false
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading) {
            VStack(spacing: 12) {
                if job.isProcessing { ProgressView().controlSize(.large) }
                else { Image(systemName: ["retry_scheduled", "retry_paused"].contains(job.status) ? "clock.arrow.circlepath" : (job.status == "paused" ? "pause.circle" : "exclamationmark.circle")).font(.largeTitle).foregroundStyle(.secondary) }
                Text(job.latestStatus).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                if job.status == "paused" {
                    Button("Check status") { Task { await store.checkStatus(job) } }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 150)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text(job.model).font(.caption).lineLimit(1)
            if job.canCancelRetries == true {
                Button("Stop retries", systemImage: "stop.circle") { confirmStopRetries = true }
                    .font(.caption).disabled(removing)
            }
            Button("Remove tile", systemImage: "trash", role: .destructive) { confirmRemove = true }
                .font(.caption).disabled(removing || job.status == "submitting")
        }
        .confirmationDialog(
            job.canCancelRetries == true ? "Remove this tile and stop its automatic retries? An already accepted request can still finish." : (["failed", "canceled"].contains(job.status) ? "Remove this generation from the shared gallery?" : "Remove this tile? This does not cancel a submitted request. Any completed images will still appear."),
            isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove tile", role: .destructive) {
                removing = true
                Task { _ = await store.removeJob(job); removing = false }
            }
        }
        .confirmationDialog("Stop automatic retries? A request already accepted by Replicate can still finish.", isPresented: $confirmStopRetries, titleVisibility: .visible) {
            Button("Stop retries", role: .destructive) {
                removing = true
                Task { _ = await store.cancelRetries(job); removing = false }
            }
        }
        .contextMenu { Button("Show details") { store.error = job.latestStatus } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generation, \(job.latestStatus)")
    }
}
private struct ServerGenerationImage: View {
    let output: GenerationOutput
    var maximum = 512
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var phase
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: pairing.credential?.deviceID) { await load() }
        .onChange(of: phase) { _, value in
            if value != .active { image = nil }
            else { Task { await load() } }
        }
        .onDisappear { image = nil }
    }
    private func load() async {
        image = nil; failed = false
        do {
            let data = try await store.imageData(output)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximum
                  ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
            let decoded = UIImage(cgImage: thumbnail)
            try Task.checkCancellation()
            image = decoded
        } catch { failed = true }
    }
}
struct GenerationComposer: View {
    let initialModel: GenerationModel?
    let draft: GenerationDraft?
    @State private var modelID: String
    init(model: GenerationModel) {
        initialModel = model; draft = nil
        _modelID = State(initialValue: model.id)
    }
    init(draft: GenerationDraft, models: [GenerationModel]) {
        self.draft = draft
        let settings = draft.details.settings
        let model = draft.matchingModel(in: models)
        initialModel = model
        _modelID = State(initialValue: model?.id ?? "")
        _useModel = State(initialValue: true)
        _prompt = State(initialValue: settings.prompt)
        _ratio = State(initialValue: settings.aspectRatio ?? "match_input_image")
        _scale = State(initialValue: settings.loraScale ?? 1)
        _seed = State(initialValue: settings.seed.map(String.init) ?? "")
        _retryOffline = State(initialValue: settings.retryOffline ?? true)
        _sourceOutputID = State(initialValue: draft.details.hasInput ? draft.output.id : nil)
    }
    private var model: GenerationModel? { store.models.first { $0.id == modelID } ?? (draft == nil && initialModel?.id == modelID ? initialModel : nil) }
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var useModel = false
    @State private var photo: PhotosPickerItem?
    @State private var image: Data?
    @State private var sourceOutputID: String?
    @State private var prompt = ""
    @State private var ratio = "match_input_image"
    @State private var scale = 1.0
    @State private var seed = ""
    @State private var retryOffline = true
    @State private var files = false
    @State private var importing = false
    @State private var importError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    if draft != nil {
                        Picker("Model", selection: $modelID) {
                            Text("Choose a model").tag("")
                            ForEach(store.models.filter(\.supported)) { Text($0.displayName).tag($0.id) }
                        }
                        if model == nil || model?.supported == false {
                            Text("The original model is unavailable or unsupported. Choose an available model before generating.").foregroundStyle(.secondary)
                        }
                    }
                    if let model {
                    Text(model.displayName).font(.headline)
                    LabeledContent("Base model", value: model.baseModel ?? "Unspecified")
                    LabeledContent("Weight size", value: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    DisclosureGroup("Additional information") { Text(model.details).font(.caption.monospaced()).textSelection(.enabled) }
                    if !model.supported { Text("Generation currently supports Qwen Image Edit 2509 weights. Set the correct base model on the server.").foregroundStyle(.secondary) }
                    if !useModel { Button("Use model to generate") { useModel = true }.disabled(!model.supported) }
                    }
                    if draft?.details.legacy == true {
                        Text("Original settings were not saved. The prompt is restored; other settings use app defaults. Choose the original photo to continue.").foregroundStyle(.secondary)
                    }
                }
                if useModel {
                    Section("Input image") {
                        if let image, let preview = UIImage(data: image) { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 240) }
                        PhotosPicker("Choose from Photos", selection: $photo, matching: .images)
                        Button("Choose from Files") { files = true }
                        if importing { ProgressView("Preparing image…") }
                        if let importError { Text(importError).foregroundStyle(.red) }
                    }
                    Section("Prompt") { TextEditor(text: $prompt).frame(minHeight: 100).accessibilityLabel("Editing prompt") }
                    Section("Settings") {
                        Picker("Aspect ratio", selection: $ratio) {
                            Text("Match input image").tag("match_input_image")
                            ForEach(["1:1", "16:9", "9:16", "4:3", "3:4"], id: \.self) { Text($0).tag($0) }
                        }
                        VStack(alignment: .leading) { Text("LoRA scale: \(scale, specifier: "%.2f")"); Slider(value: $scale, in: 0...4, step: 0.05) }
                        TextField("Seed (blank for random)", text: $seed).keyboardType(.numberPad)
                        LabeledContent("Output format", value: "JPG")
                        LabeledContent("Disable safety checker", value: "True")
                        Toggle("Retry temporary failures", isOn: $retryOffline)
                        if retryOffline {
                            Text("Every 30 minutes for up to 12 hours, even while the app is closed. The server keeps the original photo while generated outputs remain. Failed requests without outputs are cleaned up after the retry window.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Generate image", systemImage: "sparkles") {
                        guard let credential = pairing.credential, let image, let model, model.supported else { return }
                        Task { await store.generate(credential: credential, model: model, image: image, prompt: prompt, ratio: ratio, scale: scale, seed: seed, retryOffline: retryOffline, sourceOutputID: sourceOutputID) }
                        dismiss()
                    }.disabled(image == nil || importing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || pairing.credential == nil || model?.supported != true)
                }
            }
            .navigationTitle(useModel ? "Generate image" : "Model details")
            .toolbar { Button("Done") { dismiss() } }
        }
        .task(id: draft?.id) {
            guard let draft, draft.details.hasInput else { return }
            importing = true
            defer { importing = false }
            do { image = try await store.originalImage(draft.output) }
            catch { sourceOutputID = nil; importError = "The original photo could not be loaded. Choose a photo to continue. " + error.localizedDescription }
        }
        .onChange(of: photo) { _, item in
            Task {
                importing = true; defer { importing = false }
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self) else { throw URLError(.cannotDecodeContentData) }
                    try prepare(data)
                } catch { image = nil; importError = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try prepare(Data(contentsOf: url))
            } catch { image = nil; importError = error.localizedDescription }
        }
    }
    private func prepare(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let preview = UIImage(cgImage: thumbnail)
        let size = preview.size
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); preview.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpg = rendered.jpegData(compressionQuality: 0.95), jpg.count < 11_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        image = jpg; sourceOutputID = nil; importError = nil
    }
}
struct GenerationDetail: View {
    let output: GenerationOutput
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var zoomed = false
    @State private var share: ExportItem?
    @State private var temporaryShare: URL?
    @State private var sharing = false
    @State private var shareTask: Task<Void, Never>?
    @State private var detailError: String?
    @State private var remove = false
    @State private var details: GenerationDetails?
    @State private var showingSettings = false
    @State private var loadingDetails = false
    @State private var draft: GenerationDraft?
    init(output: GenerationOutput) { self.output = output; _selectedID = State(initialValue: output.id) }
    private var current: GenerationOutput? { store.outputs.first { $0.id == selectedID } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GalleryPager(outputs: store.outputs, selectedID: $selectedID, zoomed: $zoomed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                if let current {
                    VStack(spacing: 8) {
                        Text(current.model).font(.headline).lineLimit(1)
                        HStack {
                            Button("View settings", systemImage: "slider.horizontal.3") { Task { await loadDetails(runAgain: false) } }
                            Spacer()
                            Button("Run again", systemImage: "arrow.clockwise") { Task { await loadDetails(runAgain: true) } }
                        }.disabled(loadingDetails)
                        if loadingDetails { ProgressView() }
                    }.padding().background(.bar)
                }
            }
            .navigationTitle(positionLabel).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        guard let current else { return }
                        sharing = true
                        shareTask = Task {
                            defer { sharing = false }
                            do { let url = try await store.prepareShare(current); temporaryShare = url; share = ExportItem(url: url) }
                            catch { detailError = error.localizedDescription }
                        }
                    }.disabled(sharing || current == nil)
                    Button("Remove", systemImage: "trash", role: .destructive) { remove = true }.disabled(current == nil)
                }
            }
        }
        .sheet(item: $share, onDismiss: cleanupShare) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $showingSettings) {
            if let details { GenerationSettingsView(details: details) }
        }
        .sheet(item: $draft) { GenerationComposer(draft: $0, models: store.models) }
        .onChange(of: selectedID) { _, _ in details = nil; zoomed = false }
        .onChange(of: store.outputs.map(\.id)) { old, new in
            guard !new.contains(selectedID) else { return }
            guard !new.isEmpty else { dismiss(); return }
            let index = old.firstIndex(of: selectedID) ?? 0
            selectedID = new[min(index, new.count - 1)]
        }
        .onChange(of: pairing.credential?.deviceID) { _, _ in dismiss() }
        .onDisappear { if share == nil { shareTask?.cancel(); cleanupShare() } }
        .alert("Image unavailable", isPresented: Binding(get: { detailError != nil }, set: { if !$0 { detailError = nil } })) {
            Button("OK") { detailError = nil }
        } message: { Text(detailError ?? "") }
        .confirmationDialog("Remove this image from the server gallery for all devices?", isPresented: $remove, titleVisibility: .visible) {
            Button("Remove image", role: .destructive) {
                guard let current else { return }
                Task { if !(await store.remove(current)) { detailError = store.error; store.error = nil } }
            }
        }
    }
    private var positionLabel: String {
        guard let index = store.outputs.firstIndex(where: { $0.id == selectedID }) else { return "Generated image" }
        return "\(index + 1) of \(store.outputs.count)"
    }
    private func loadDetails(runAgain: Bool) async {
        guard let current else { return }
        loadingDetails = true
        defer { loadingDetails = false }
        do {
            let value = try await store.generationDetails(current)
            guard current.id == selectedID else { return }
            details = value
            if runAgain { draft = GenerationDraft(output: current, details: value) }
            else { showingSettings = true }
        } catch { detailError = error.localizedDescription }
    }
    private func cleanupShare() {
        if let temporaryShare { try? FileManager.default.removeItem(at: temporaryShare) }
        temporaryShare = nil
    }
}

private struct GenerationSettingsView: View {
    let details: GenerationDetails
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                let settings = details.settings
                LabeledContent("Model", value: settings.modelName)
                LabeledContent("Base model", value: settings.baseModel ?? "Unavailable")
                if let id = settings.modelID { LabeledContent("Weight SHA", value: id).textSelection(.enabled) }
                Section("Prompt") { Text(settings.prompt).textSelection(.enabled) }
                if details.legacy { Text("Original photo and additional settings were not saved for this image.").foregroundStyle(.secondary) }
                else {
                    LabeledContent("Aspect ratio", value: settings.aspectRatio ?? "Unavailable")
                    LabeledContent("LoRA scale", value: settings.loraScale.map { String(format: "%.2f", $0) } ?? "Unavailable")
                    LabeledContent("Submitted seed", value: settings.seed.map(String.init) ?? "Random (blank)")
                    if let seed = details.resolvedSeed { LabeledContent("Resolved seed", value: String(seed)) }
                    LabeledContent("Output format", value: settings.outputFormat?.uppercased() ?? "Unavailable")
                    LabeledContent("Disable safety checker", value: settings.disableSafetyChecker == true ? "True" : "False")
                    LabeledContent("Retry temporary failures", value: settings.retryOffline == true ? "On" : "Off")
                    if !details.hasInput { Text("The original photo is no longer available. Choose a photo when running again.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Generation settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
