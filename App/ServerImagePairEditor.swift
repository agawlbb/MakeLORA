import SwiftUI
import MakeLORACore

struct ServerImagePairEditor: View {
    @ObservedObject var store: ServerDatasetStore
    let project: ServerDataset
    let initial: ServerDatasetClip
    @Environment(\.dismiss) private var dismiss
    @State private var pair: ServerDatasetClip
    @State private var side = 0
    @State private var linked = false
    @State private var saving = false
    @State private var error: String?
    init(store: ServerDatasetStore, project: ServerDataset, initial: ServerDatasetClip) {
        self.store = store; self.project = project; self.initial = initial
        var value = initial
        let ready = project.videos.filter { $0.status == "ready" }
        if value.control == nil { value.control = ready.first?.id }
        if value.target == nil { value.target = ready.dropFirst().first?.id ?? ready.first?.id }
        _pair = State(initialValue: value)
    }
    private var sources: [ServerDatasetVideo] { store.project?.videos.filter { $0.status == "ready" } ?? [] }
    private var source: ServerDatasetVideo? { sources.first { $0.id == (side == 0 ? pair.control : pair.target) } }
    private var crop: Binding<Crop> {
        Binding(get: {
            let c = side == 0 ? pair.controlCrop : pair.targetCrop
            return c.map { Crop(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .full
        }, set: { c in
            let value = ServerDatasetCrop(x: c.x, y: c.y, width: c.width, height: c.height)
            if side == 0 || linked { pair.controlCrop = value }
            if side == 1 || linked { pair.targetCrop = value }
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Control", selection: Binding(get: { pair.control ?? "" }, set: { pair.control = $0; pair.controlCrop = nil })) {
                        ForEach(sources) { Text($0.name).tag($0.id) }
                    }
                    Picker("Target", selection: Binding(get: { pair.target ?? "" }, set: { pair.target = $0; pair.targetCrop = nil })) {
                        ForEach(sources) { Text($0.name).tag($0.id) }
                    }
                    Button("Swap control and target") {
                        let id = pair.control; pair.control = pair.target; pair.target = id
                        let c = pair.controlCrop; pair.controlCrop = pair.targetCrop; pair.targetCrop = c
                    }
                }
                Section("Crop") {
                    Picker("Side", selection: $side) { Text("Control").tag(0); Text("Target").tag(1) }.pickerStyle(.segmented)
                    if let source, let url = source.previewURL {
                        GeometryReader { bounds in
                            let size = VideoCropGeometry.fitted(aspect: Double(source.width ?? 1) / Double(source.height ?? 1), width: bounds.size.width, height: bounds.size.height)
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                                .frame(width: size.width, height: size.height)
                                .overlay { VideoEditorCropOverlay(crop: crop, normalizedAspect: nil, interacting: { store.noteActivity() }) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(height: 260)
                    }
                    Toggle("Apply crop to both", isOn: $linked)
                    slider("Width", key: \.width, range: 0.05...1)
                    slider("Height", key: \.height, range: 0.05...1)
                    slider("Left", key: \.x, range: 0...max(0.0001, 1-crop.wrappedValue.width))
                    slider("Top", key: \.y, range: 0...max(0.0001, 1-crop.wrappedValue.height))
                    Button("Reset crop") { crop.wrappedValue = .full }
                }
                Section("Caption") { TextEditor(text: $pair.caption).frame(minHeight: 100) }
                if let error { Text(error).foregroundStyle(.red); Button("Retry access") { Task { await checkAccess() } } }
            }.navigationTitle("Image pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do { try await store.saveClip(pair, original: project.clips.first { $0.id == initial.id }, projectID: project.id); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(pair.control == nil || pair.target == nil || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: pair) { _, _ in store.noteActivity() }
            .onChange(of: side) { _, _ in store.noteActivity() }
            .task { await checkAccess() }
        }
    }
    private func checkAccess() async {
        do { try await store.open(project.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func slider(_ label: String, key: WritableKeyPath<Crop, Double>, range: ClosedRange<Double>) -> some View {
        VStack {
            HStack { Text(label); Spacer(); Text(crop.wrappedValue[keyPath: key], format: .percent.precision(.fractionLength(0))) }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, crop.wrappedValue[keyPath: key])) }, set: { value in
                var c = crop.wrappedValue; c[keyPath: key] = value; c.x = min(c.x, 1-c.width); c.y = min(c.y, 1-c.height); crop.wrappedValue = c
            }), in: range)
        }
    }
}
