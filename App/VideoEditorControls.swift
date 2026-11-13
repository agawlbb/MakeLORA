import SwiftUI
import AVKit
import MakeLORACore

struct VideoEditorMedia {
    let url: URL
    var thumbnails: [URL]? = nil
}

@MainActor final class VideoEditorPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    private var observer: Any?
    private var seeking = false
    private var seekNumber = 0
    func load(_ url: URL, at time: Double) {
        stop()
        let current = AVPlayer(url: url); player = current
        observer = current.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak current] time in
            Task { @MainActor in
                guard let self, self.player === current else { return }
                if !self.seeking, time.seconds.isFinite { self.position = max(0, time.seconds) }
                self.playing = (current?.rate ?? 0) > 0
            }
        }
        seek(time)
    }
    func seek(_ time: Double) {
        guard time.isFinite, let player else { return }
        pause(); position = max(0, time); seeking = true; seekNumber += 1
        let number = seekNumber
        player.currentItem?.forwardPlaybackEndTime = .invalid
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in if self?.seekNumber == number { self?.seeking = false } }
        }
    }
    func play(start: Double, end: Double) {
        guard let player else { return }
        if position < start || position >= end - 0.001 { seek(start) }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
        player.play(); playing = true
    }
    func pause() { player?.pause(); playing = false }
    func stop() {
        pause(); seekNumber += 1
        if let observer { player?.removeTimeObserver(observer); self.observer = nil }
        player?.replaceCurrentItem(with: nil); player = nil
    }
}

private final class VideoEditorLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct VideoEditorSurface: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> UIView {
        let view = VideoEditorLayerView(); view.videoLayer.videoGravity = .resizeAspect; view.backgroundColor = .black; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { (uiView as? VideoEditorLayerView)?.videoLayer.player = player }
}

func videoEditorTime(_ time: Double) -> String {
    let value = max(0, time.isFinite ? time : 0)
    return String(format: "%02d:%06.3f", Int(value)/60, value.truncatingRemainder(dividingBy: 60))
}

struct VideoEditorTimeline: View {
    let media: VideoEditorMedia
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var position: Double
    private let padding = 18.0
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Start \(videoEditorTime(start))").foregroundStyle(.yellow)
                Spacer()
                Text("End \(videoEditorTime(end))").foregroundStyle(.orange)
            }.font(.caption.monospacedDigit())
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - padding*2)
                ZStack(alignment: .topLeading) {
                    thumbnails.frame(width: width, height: 70).clipped().offset(x: padding, y: 5)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in position = min(duration, max(0, value.location.x/width*duration)) })
                    Rectangle().fill(.black.opacity(0.55)).frame(width: width*start/duration, height: 70).offset(x: padding, y: 5).allowsHitTesting(false)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: width*(1-end/duration), height: 70).offset(x: padding+width*end/duration, y: 5).allowsHitTesting(false)
                    Rectangle().stroke(.yellow, lineWidth: 2).frame(width: max(1, width*(end-start)/duration), height: 70).offset(x: padding+width*start/duration, y: 5).allowsHitTesting(false)
                    Rectangle().fill(.white).frame(width: 2, height: 80).offset(x: padding+width*min(duration,max(0,position))/duration-1).allowsHitTesting(false)
                    handle("Start", time: $start, color: .yellow, y: 20, width: width)
                    handle("End", time: $end, color: .orange, y: 60, width: width)
                }.coordinateSpace(name: "videoEditorTimeline")
            }.frame(height: 80)
            Text("Drag yellow Start or orange End. Tap the pictures to move the white playhead.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var thumbnails: some View {
        HStack(spacing: 1) {
            ForEach(0..<8) { i in
                GeometryReader { proxy in
                    Group {
                        if let urls = media.thumbnails, urls.indices.contains(i) {
                            AsyncImage(url: urls[i]) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        } else if media.url.isFileURL { VideoFrame(url: media.url, time: duration*Double(i)/8) }
                        else { Color.gray.opacity(0.2) }
                    }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            }
        }
    }
    private func handle(_ title: String, time: Binding<Double>, color: Color, y: Double, width: Double) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color)
            .frame(width: 25, height: 36)
            .overlay(Text(title == "Start" ? "S" : "E").font(.caption.bold()).foregroundStyle(.black))
            .frame(width: 36, height: 40).contentShape(Rectangle())
            .position(x: padding+width*time.wrappedValue/duration, y: y)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("videoEditorTimeline")).onChanged { value in
                time.wrappedValue = min(duration, max(0, (value.location.x-padding)/width*duration))
            })
            .accessibilityLabel("Trim \(title.lowercased())")
            .accessibilityValue(videoEditorTime(time.wrappedValue))
            .accessibilityAdjustableAction { direction in time.wrappedValue += direction == .increment ? 0.1 : -0.1 }
    }
}

struct VideoEditorCropOverlay: View {
    @Binding var crop: Crop
    let normalizedAspect: Double?
    var interacting: () -> Void
    @State private var moveOrigin: Crop?
    @State private var resizeOrigin: Crop?
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let rect = CGRect(x: crop.x*w, y: crop.y*h, width: crop.width*w, height: crop.height*h)
            ZStack(alignment: .topLeading) {
                Path { path in path.addRect(CGRect(origin: .zero, size: geometry.size)); path.addRect(rect) }
                    .fill(.black.opacity(0.6), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle()).overlay(Rectangle().stroke(.yellow, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        interacting(); if moveOrigin == nil { moveOrigin = crop }
                        crop = VideoCropGeometry.move(moveOrigin ?? crop, dx: value.translation.width/w, dy: value.translation.height/h)
                    }.onEnded { _ in moveOrigin = nil })
                    .accessibilityLabel("Crop selection").accessibilityHint("Drag inside to move the selected area.")
                ForEach(Array(VideoCropCorner.allCases.enumerated()), id: \.offset) { _, corner in
                    cornerHandle(corner, rect: rect, size: geometry.size)
                }
            }
        }
    }
    private func cornerHandle(_ corner: VideoCropCorner, rect: CGRect, size: CGSize) -> some View {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return Circle().fill(.yellow).overlay(Circle().stroke(.black, lineWidth: 1))
            .frame(width: 20, height: 20).frame(width: 40, height: 40).contentShape(Rectangle())
            .position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                interacting(); if resizeOrigin == nil { resizeOrigin = crop }
                crop = VideoCropGeometry.resize(resizeOrigin ?? crop, corner: corner, dx: value.translation.width/size.width, dy: value.translation.height/size.height, normalizedAspect: normalizedAspect)
            }.onEnded { _ in resizeOrigin = nil })
            .accessibilityLabel("\(top ? "Top" : "Bottom") \(left ? "left" : "right") crop corner")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.01 : -0.01
                interacting()
                crop = VideoCropGeometry.resize(crop, corner: corner, dx: left ? -step : step, dy: top ? -step : step, normalizedAspect: normalizedAspect)
            }
    }
}
