import SwiftUI
import AVKit

struct ServerClipEditor: View {
    @ObservedObject var store: ServerDatasetStore
    let project: ServerDataset
    let video: ServerDatasetVideo
    let initial: ServerDatasetClip
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerDatasetClip
    @State private var player: AVPlayer?
    @State private var boundary: Any?
    @State private var saving = false
    @State private var error: String?
    init(store: ServerDatasetStore, project: ServerDataset, video: ServerDatasetVideo, initial: ServerDatasetClip) {
        self.store = store; self.project = project; self.video = video; self.initial = initial
        _draft = State(initialValue: initial)
    }
    private var duration: Double { video.duration ?? initial.end }
    private var crop: ServerDatasetCrop { draft.crop ?? ServerDatasetCrop() }
    private var ratio: Double { Double(video.width ?? 16) / Double(video.height ?? 9) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(ratio, contentMode: .fit)
                            .overlay {
                                if draft.crop != nil {
                                    GeometryReader { geometry in
                                        Rectangle().stroke(.yellow, lineWidth: 2)
                                            .frame(width: geometry.size.width * crop.width, height: geometry.size.height * crop.height)
                                            .offset(x: geometry.size.width * crop.x, y: geometry.size.height * crop.y)
                                    }.allowsHitTesting(false)
                                }
                            }
                    } else { Text("Preview unavailable. Reopen the dataset to refresh its preview link.") }
                    if let urls = video.thumbnails {
                        HStack(spacing: 1) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                                Button { seek(duration * Double(index) / 8) } label: {
                                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.2) }
                                }.buttonStyle(.plain)
                            }
                        }.frame(height: 44)
                    }
                    Button("Preview trimmed clip", systemImage: "play.fill") { seek(draft.start); player?.play() }
                } header: { Text(video.name) }
                Section("Trim") {
                    Text(String(format: "Start %.2f s · End %.2f s · Length %.2f s", draft.start, draft.end, draft.end - draft.start)).monospacedDigit()
                    Slider(value: Binding(get: { min(max(0, draft.start), max(0, draft.end - 0.1)) }, set: { draft.start = $0 }), in: 0...max(0, draft.end - 0.1)) { Text("Start") }
                        .accessibilityLabel("Trim start")
                    Slider(value: Binding(get: { min(duration, max(min(duration, draft.start + 0.1), draft.end)) }, set: { draft.end = $0 }), in: min(duration, draft.start + 0.1)...duration) { Text("End") }
                        .accessibilityLabel("Trim end")
                    HStack {
                        Text("Start (seconds)")
                        TextField("Start", value: $draft.start, format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("End (seconds)")
                        TextField("End", value: $draft.end, format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                Section("Optional crop") {
                    Toggle("Crop video", isOn: Binding(get: { draft.crop != nil }, set: { draft.crop = $0 ? ServerDatasetCrop() : nil }))
                    if draft.crop != nil {
                        cropSlider("Left", keyPath: \.x, range: 0...max(0, 1 - crop.width))
                        cropSlider("Top", keyPath: \.y, range: 0...max(0, 1 - crop.height))
                        cropSlider("Width", keyPath: \.width, range: 0.05...max(0.05, 1 - crop.x))
                        cropSlider("Height", keyPath: \.height, range: 0.05...max(0.05, 1 - crop.y))
                        Button("Reset crop") { draft.crop = ServerDatasetCrop() }
                    }
                    Text("Export preserves the selected shape and resizes its shorter side to 480 pixels.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Caption") {
                    TextEditor(text: $draft.caption).frame(minHeight: 120).accessibilityLabel("Clip caption")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit server clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true; error = nil; defer { saving = false }
                            do {
                                guard draft.start.isFinite, draft.end.isFinite, draft.start >= 0, draft.end <= duration, draft.end - draft.start >= 0.09999 else {
                                    throw NSError(domain: "Dataset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a trim inside the video of at least 0.1 seconds."])
                                }
                                try await store.saveClip(draft, original: project.clips.first { $0.id == initial.id }, projectID: project.id)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                if let url = video.previewURL { player = AVPlayer(url: url); seek(draft.start); updateBoundary() }
            }
            .onDisappear {
                player?.pause()
                if let boundary { player?.removeTimeObserver(boundary); self.boundary = nil }
                player = nil
            }
            .onChange(of: draft.start) { _, value in if value.isFinite && value >= 0 && value <= duration { player?.pause(); seek(value) } }
            .onChange(of: draft.end) { _, value in if value.isFinite && value > 0 && value <= duration { player?.pause(); updateBoundary(); seek(max(0, value - 0.1)) } }
        }
    }
    private func cropSlider(_ label: String, keyPath: WritableKeyPath<ServerDatasetCrop, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(label) · \(Int((crop[keyPath: keyPath] * 100).rounded()))%")
            Slider(value: Binding(get: { crop[keyPath: keyPath] }, set: { var value = crop; value[keyPath: keyPath] = $0; draft.crop = value }), in: range).accessibilityLabel(label)
        }
    }
    private func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func updateBoundary() {
        if let boundary { player?.removeTimeObserver(boundary); self.boundary = nil }
        guard draft.end.isFinite else { return }
        boundary = player?.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: draft.end, preferredTimescale: 600))], queue: .main) { [weak player] in player?.pause() }
    }
}
