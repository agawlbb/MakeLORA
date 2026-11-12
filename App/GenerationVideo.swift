import SwiftUI
import AVKit

struct ServerVideoPoster: View {
    let output: GenerationOutput
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Label("Video unavailable", systemImage: "video.slash") }
            else { ProgressView() }
            Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 3)
        }
        .task(id: pairing.credential?.deviceID) {
            image = nil; failed = false
            do {
                let url = try await store.videoFile(output)
                defer { try? FileManager.default.removeItem(at: url) }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
                let frame = try await generator.image(at: .zero)
                try Task.checkCancellation(); image = UIImage(cgImage: frame.image)
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onDisappear { image = nil }
    }
}

struct ServerVideoPlayer: View {
    let output: GenerationOutput
    let active: Bool
    @EnvironmentObject private var store: GenerationStore
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var phase
    @State private var player: AVPlayer?
    @State private var url: URL?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else if let failure { VStack { Text(failure); Button("Retry") { retry += 1 } } }
            else { ProgressView("Loading video…") }
        }
        .task(id: "\(active)-\(retry)-\(phase == .active)-\(pairing.credential?.deviceID ?? "")") {
            cleanup(); failure = nil
            guard active, phase == .active, pairing.credential != nil else { return }
            do {
                let file = try await store.videoFile(output)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: file); return }
                url = file; player = AVPlayer(url: file)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onDisappear(perform: cleanup)
        .accessibilityLabel("Generated video, \(output.model)")
    }
    private func cleanup() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
    }
}

struct SingleGalleryImage: View {
    let output: GenerationOutput
    @EnvironmentObject private var store: GenerationStore
    @State private var selectedID: String
    @State private var zoomed = false
    init(output: GenerationOutput) { self.output = output; _selectedID = State(initialValue: output.id) }
    var body: some View {
        GalleryPages(outputs: [output], selectedID: $selectedID, zoomed: $zoomed) { try await store.imageData($0) }
    }
}
