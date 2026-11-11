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
            Task { await store.resume() }
            await store.watchGallery()
        }
        .sheet(isPresented: $serverSettings) { ServerView() }
        .sheet(item: $selectedModel) { GenerationComposer(model: $0) }
        .sheet(item: $selectedOutput) { GenerationDetail(output: $0) }
        .onChange(of: pairing.credential?.deviceID) { _, _ in selectedOutput = nil; selectedModel = nil }
        .alert("Generation needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
private struct GenerationProgressTile: View {
    let job: GenerationJob
    @EnvironmentObject private var store: GenerationStore
    var body: some View {
        VStack(alignment: .leading) {
            VStack(spacing: 12) {
                if job.isProcessing { ProgressView().controlSize(.large) }
                else { Image(systemName: job.status == "paused" ? "pause.circle" : "exclamationmark.circle").font(.largeTitle).foregroundStyle(.secondary) }
                Text(job.latestStatus).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                if job.status == "paused" && store.hasPending {
                    Button("Resume") { Task { await store.resume() } }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 150)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text(job.model).font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upcoming image, \(job.latestStatus)")
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
private struct GenerationComposer: View {
    let model: GenerationModel
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var useModel = false
    @State private var photo: PhotosPickerItem?
    @State private var image: Data?
    @State private var prompt = ""
    @State private var ratio = "match_input_image"
    @State private var scale = 1.0
    @State private var seed = ""
    @State private var files = false
    @State private var importing = false
    @State private var importError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Text(model.displayName).font(.headline)
                    LabeledContent("Base model", value: model.baseModel ?? "Unspecified")
                    LabeledContent("Weight size", value: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    DisclosureGroup("Additional information") { Text(model.details).font(.caption.monospaced()).textSelection(.enabled) }
                    if !model.supported { Text("Generation currently supports Qwen Image Edit 2509 weights. Set the correct base model on the server.").foregroundStyle(.secondary) }
                    if !useModel { Button("Use model to generate") { useModel = true }.disabled(!model.supported) }
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
                    }
                    Button("Generate image", systemImage: "sparkles") {
                        guard let credential = pairing.credential, let image else { return }
                        Task { await store.generate(credential: credential, model: model, image: image, prompt: prompt, ratio: ratio, scale: scale, seed: seed) }
                        dismiss()
                    }.disabled(image == nil || importing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || store.hasPending || pairing.credential == nil)
                }
            }
            .navigationTitle(useModel ? "Generate image" : "Model details")
            .toolbar { Button("Done") { dismiss() } }
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
        image = jpg; importError = nil
    }
}
private struct GenerationDetail: View {
    let output: GenerationOutput
    @EnvironmentObject private var store: GenerationStore
    @Environment(\.dismiss) private var dismiss
    @State private var share: ExportItem?
    @State private var temporaryShare: URL?
    @State private var sharing = false
    @State private var shareTask: Task<Void, Never>?
    @State private var detailError: String?
    @State private var remove = false
    var body: some View {
        NavigationStack {
            ScrollView {
                ServerGenerationImage(output: output, maximum: 2048)
                VStack(alignment: .leading, spacing: 12) {
                    Text(output.model).font(.headline)
                    Text(output.prompt).textSelection(.enabled)
                    Text(output.date.formatted()).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("Generated image").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        sharing = true
                        shareTask = Task {
                            defer { sharing = false }
                            do {
                                let url = try await store.prepareShare(output)
                                temporaryShare = url; share = ExportItem(url: url)
                            } catch { detailError = error.localizedDescription }
                        }
                    }.disabled(sharing)
                    Button("Remove", systemImage: "trash", role: .destructive) { remove = true }
                }
            }
        }
        .sheet(item: $share, onDismiss: cleanupShare) { ShareSheet(url: $0.url) }
        .onDisappear {
            if share == nil { shareTask?.cancel(); cleanupShare() }
        }
        .alert("Image unavailable", isPresented: Binding(get: { detailError != nil }, set: { if !$0 { detailError = nil } })) {
            Button("OK") { detailError = nil }
        } message: { Text(detailError ?? "") }
        .confirmationDialog("Remove this image from the server gallery for all devices?", isPresented: $remove, titleVisibility: .visible) {
            Button("Remove image", role: .destructive) {
                Task {
                    if await store.remove(output) { dismiss() }
                    else { detailError = store.error; store.error = nil }
                }
            }
        }
    }
    private func cleanupShare() {
        if let temporaryShare { try? FileManager.default.removeItem(at: temporaryShare) }
        temporaryShare = nil
    }

}
