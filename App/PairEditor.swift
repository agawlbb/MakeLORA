import SwiftUI
import MakeLORACore

struct PhotoThumbnail: View {
    @EnvironmentObject private var store: ProjectStore
    let photoID: UUID
    var crop: Crop = .full
    var maximum = 900
    @State private var image: UIImage?
    @State private var failed = false
    private var key: String { "\(photoID)-\(crop)-\(maximum)" }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.035)
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height) }
                else if failed { Label("Image unavailable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: key) {
            image = nil; failed = false
            guard let photo = store.project?.photos.first(where: { $0.id == photoID }), let url = store.original(photo) else { failed = true; return }
            let result = await store.engine.thumbnail(url: url, crop: crop, maximum: maximum)
            guard !Task.isCancelled else { return }
            image = result; failed = result == nil
        }
    }
}

struct PairEditor: View {
    let pairID: Int
    @EnvironmentObject private var store: ProjectStore
    @State private var replacement: Side?
    @State private var cropping: Side?
    @State private var delete = false
    @FocusState private var captionFocused: Bool
    private var pair: ImagePair? { store.project?.pairs.first { $0.id == pairID } }
    var body: some View {
        if let pair {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PAIR \(pair.id)").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                            Text("Describe the transformation").font(.title2.weight(.semibold))
                        }
                        Spacer()
                        Button("Swap", systemImage: "arrow.left.arrow.right") { store.editPair(pairID) { $0.swap() } }.buttonStyle(.bordered)
                        Button(role: .destructive) { delete = true } label: { Image(systemName: "trash") }.buttonStyle(.bordered).accessibilityLabel("Delete pair")
                    }
                    HStack(alignment: .top, spacing: 18) {
                        imageCard(pair, side: .control)
                        imageCard(pair, side: .target)
                    }
                    HStack {
                        Label("Transformation caption", systemImage: "text.alignleft").font(.subheadline.weight(.semibold))
                        Spacer()
                        if captionFocused { Button("Done") { captionFocused = false } }
                        Text("target/\(pair.id).txt").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    TextEditor(text: Binding(get: { self.pair?.caption ?? "" }, set: { text in store.editPair(pairID) { $0.caption = text } }))
                        .focused($captionFocused).font(.body).scrollContentBackground(.hidden)
                        .frame(minHeight: 95, maxHeight: 140).padding(10)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            if pair.caption.isEmpty { Text("For example: Replace the cloudy sky with a warm sunset.").foregroundStyle(.tertiary).padding(15).allowsHitTesting(false) }
                        }.accessibilityLabel("Transformation caption")
                    Label("Edits save automatically. Originals are preserved.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .sheet(item: $replacement) { side in PhotoChooser(title: "Replace \(side.title)") { photo in
                store.editPair(pairID) { value in
                    if side == .control { value.control = photo.id; value.controlCrop = .full }
                    else { value.target = photo.id; value.targetCrop = .full }
                }
            } }
            .sheet(item: $cropping) { side in CropEditor(pair: pair, side: side) }
            .confirmationDialog("Delete pair \(pair.id)? Library photos will remain available.", isPresented: $delete, titleVisibility: .visible) {
                Button("Delete pair", role: .destructive) { store.update { $0.pairs.removeAll { $0.id == pairID } } }
            }
        }
    }
    private func imageCard(_ pair: ImagePair, side: Side) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(side.title.uppercased()).font(.caption.weight(.bold)).tracking(2)
                Spacer()
                Text(side == .control ? "Starting image" : "Desired result").font(.caption).foregroundStyle(.secondary)
            }
            PhotoThumbnail(photoID: side == .control ? pair.control : pair.target, crop: side == .control ? pair.controlCrop : pair.targetCrop)
                .frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("\(side == .control ? "control" : "target")/\(pair.id).jpg").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Crop", systemImage: "crop") { captionFocused = false; cropping = side }.labelStyle(.iconOnly).accessibilityLabel("Crop \(side.title)")
                Button("Replace", systemImage: "photo.badge.plus") { captionFocused = false; replacement = side }.labelStyle(.iconOnly).accessibilityLabel("Replace \(side.title)")
            }.buttonStyle(.bordered)
        }.padding(16).frame(maxWidth: .infinity).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}

enum Side: String, Identifiable {
    case control, target
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct PhotoChooser: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    let choose: (LibraryPhoto) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 16) {
                    ForEach(store.project?.photos ?? []) { photo in
                        Button { choose(photo); dismiss() } label: {
                            VStack(alignment: .leading) {
                                PhotoThumbnail(photoID: photo.id, maximum: 350).frame(height: 150).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(photo.name).font(.caption).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct NewPairView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let created: (Int) -> Void
    @State private var control: UUID?
    @State private var target: UUID?
    @State private var choosing: Side?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Start with two images").font(.largeTitle.weight(.semibold))
                Text("Photos can be reused across pairs. Add the caption and adjust crops in the editor.").foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    slot(.control, id: control)
                    Image(systemName: "arrow.right").font(.title).foregroundStyle(.secondary)
                    slot(.target, id: target)
                }
                Spacer(minLength: 0)
            }.padding(28)
                .navigationTitle("New pair").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create pair") {
                            guard let control, let target else { return }
                            var id: Int?
                            store.update { id = $0.addPair(control: control, target: target) }
                            if let id, store.project?.pairs.contains(where: { $0.id == id }) == true { created(id); dismiss() }
                        }.disabled(control == nil || target == nil)
                    }
                }
                .sheet(item: $choosing) { side in PhotoChooser(title: "Choose \(side.title)") { photo in if side == .control { control = photo.id } else { target = photo.id } } }
        }.presentationDetents([.large])
    }
    private func slot(_ side: Side, id: UUID?) -> some View {
        Button { choosing = side } label: {
            VStack(spacing: 12) {
                Text(side.title).font(.headline)
                if let id { PhotoThumbnail(photoID: id).frame(height: 260) }
                else { Image(systemName: "photo.badge.plus").font(.system(size: 44)).frame(height: 260) }
                Text(id == nil ? "Choose photo" : "Change photo").font(.subheadline)
            }.frame(maxWidth: .infinity).padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}
