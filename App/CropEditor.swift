import SwiftUI
import MakeLORACore

struct CropEditor: View {
    let pair: ImagePair
    let side: Side
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var crop: Crop
    @State private var linked = false
    @State private var image: UIImage?
    @State private var dragStart: CGPoint?
    init(pair: ImagePair, side: Side) {
        self.pair = pair; self.side = side
        _crop = State(initialValue: side == .control ? pair.controlCrop : pair.targetCrop)
    }
    private var photoID: UUID { side == .control ? pair.control : pair.target }
    var body: some View {
        NavigationStack {
            GeometryReader { bounds in
                let wide = bounds.size.width >= 750 && bounds.size.width > bounds.size.height
                let layout = wide ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 20))
                layout {
                    GeometryReader { geometry in
                        if let image {
                            let size = fitted(image.size, into: geometry.size)
                            ZStack(alignment: .topLeading) {
                                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                                Path { path in
                                    path.addRect(CGRect(origin: .zero, size: size))
                                    path.addRect(CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height))
                                }.fill(.black.opacity(0.65), style: FillStyle(eoFill: true))
                                Rectangle().stroke(.white, lineWidth: 2).frame(width: crop.width * size.width, height: crop.height * size.height).offset(x: crop.x * size.width, y: crop.y * size.height)
                            }.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                                let start = dragStart ?? value.startLocation
                                dragStart = start
                                let x1 = min(1, max(0, start.x / size.width)), y1 = min(1, max(0, start.y / size.height))
                                let x2 = min(1, max(0, value.location.x / size.width)), y2 = min(1, max(0, value.location.y / size.height))
                                crop = Crop(x: min(x1, x2), y: min(y1, y2), width: abs(x2-x1), height: abs(y2-y1)).clamped
                            }.onEnded { _ in dragStart = nil })
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                            .accessibilityLabel("Crop preview. Use the percentage sliders to adjust the crop.")
                        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .frame(height: wide ? nil : max(180, bounds.size.height * 0.38))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Crop \(side.title.lowercased())").font(.title2.bold())
                            Text("Drag a rectangle on the image, or adjust the percentages below.").font(.subheadline).foregroundStyle(.secondary)
                            slider("Width", key: \.width, range: 0.01...1)
                            slider("Height", key: \.height, range: 0.01...1)
                            slider("Left", key: \.x, range: 0...max(0.0001, 1-crop.width))
                            slider("Top", key: \.y, range: 0...max(0.0001, 1-crop.height))
                            Toggle("Apply same relative crop to both photos", isOn: $linked)
                            Text("The same percentages are used for both images, even when their sizes differ.").font(.caption).foregroundStyle(.secondary)
                            Button("Reset crop", systemImage: "arrow.counterclockwise") { crop = .full }.buttonStyle(.bordered)
                            Text("Your originals stay untouched. Cancel discards this crop adjustment.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width: wide ? 270 : nil)
                }.padding(16)
            }
            .navigationTitle("Nondestructive crop").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply crop") {
                        store.editPair(pair.id) { value in
                            if linked || side == .control { value.controlCrop = crop.clamped }
                            if linked || side == .target { value.targetCrop = crop.clamped }
                        }
                        dismiss()
                    }.disabled(image == nil)
                }
            }
            .task {
                if let photo = store.project?.photos.first(where: { $0.id == photoID }), let url = store.original(photo) {
                    image = await store.engine.thumbnail(url: url, crop: .full, maximum: 1400)
                    if image == nil { store.error = "Cannot load the crop preview. Replace this pair's source photo and try again."; dismiss() }
                }
            }
        }.presentationDetents([.large])
    }
    private func slider(_ label: String, key: WritableKeyPath<Crop, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label); Spacer(); Text(crop[keyPath: key], format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, crop[keyPath: key])) }, set: { value in crop[keyPath: key] = value; crop = crop.clamped }), in: range).accessibilityLabel(label)
        }
    }
    private func fitted(_ image: CGSize, into bounds: CGSize) -> CGSize {
        let scale = min(bounds.width/image.width, bounds.height/image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
