import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import AVKit
import MakeLORACore

struct ImportedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORAVideoImport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return ImportedVideo(url: url)
        }
    }
}

struct VideoWorkspaceView: View {
    let projectID: UUID
    @EnvironmentObject private var store: ProjectStore
    @State private var selected: Int?
    @State private var files = false
    @State private var pendingFiles: VideoFileSelection?
    @State private var photos: [PhotosPickerItem] = []
    @State private var share: ExportItem?
    @State private var exportURL: URL?
    @State private var delete = false
    @State private var rename = false
    @State private var name = ""
    private var project: Project { store.project ?? Project(name: "", model: .wan21I2V14B) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(project.model.title).font(.headline)
                    Text("Trim and caption your clips. Export matching MP4 and TXT files in one folder.").foregroundStyle(.secondary)
                    PhotosPicker("Import from Photos", selection: $photos, maxSelectionCount: 100, matching: .videos, preferredItemEncoding: .current)
                    Button("Import videos and captions from Files") { files = true }
                }
                Section("Clips · \(project.samples.count)") {
                    ForEach(project.samples) { sample in
                        if let video = project.videos.first(where: { $0.id == sample.video }), let url = store.original(video) {
                            Button { selected = sample.id } label: {
                                HStack {
                                    VideoFrame(url: url, time: sample.start).frame(width: 90, height: 60).clipped()
                                    VStack(alignment: .leading) {
                                        Text("Clip \(sample.id) · \(video.name)").lineLimit(1)
                                        Text(sample.caption.isEmpty ? "Add a caption" : sample.caption).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                        Text("\(sample.end - sample.start, specifier: "%.2f") seconds").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }.onDelete { offsets in store.update { $0.samples.remove(atOffsets: offsets) } }
                }
                Section { Text(store.status).font(.caption); Text("480p · aspect ratio preserved · H.264 MP4 · no audio. Originals remain untouched.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(project.name)
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { VideoSampleEditor(sampleID: selected) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Projects", systemImage: "chevron.left") { store.close() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename project") { name = project.name; rename = true }
                        Button("Retry conversion") { store.retry() }
                        Button("Delete project", role: .destructive) { delete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button("Export dataset", systemImage: "square.and.arrow.up") { Task { if let url = await store.export() { exportURL = url; share = ExportItem(url: url) } } }.disabled(project.samples.isEmpty)
                }
            }
        }
        .sheet(item: $share, onDismiss: cleanupShare) { ShareSheet(url: $0.url) }
        .sheet(isPresented: $files, onDismiss: importSelectedFiles) {
            VideoFilesPicker(onSelection: { urls in
                pendingFiles = VideoFileSelection(urls: urls)
                files = false
            }, onCancel: { pendingFiles = nil; files = false })
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                store.beginImport()
                defer { photos = []; store.setImporting(false) }
                for item in items {
                    if store.cancelRequested { break }
                    do {
                        guard let movie = try await item.loadTransferable(type: ImportedVideo.self) else { throw ProjectError.invalid("Download the original video from iCloud and try again.") }
                        defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
                        await store.importVideos([movie.url])
                        store.setImporting(true)
                    } catch { store.report("Import video", error) }
                }
            }
        }
        .alert("Rename project", isPresented: $rename) {
            TextField("Project name", text: $name)
            Button("Save") { store.update { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete this project and all its original videos?", isPresented: $delete, titleVisibility: .visible) { Button("Delete project", role: .destructive) { store.deleteProject() } }
        .onChange(of: project.samples.map(\.id)) { _, ids in if let selected, !ids.contains(selected) { self.selected = nil } }
    }
    private func importSelectedFiles() {
        guard let selection = pendingFiles else { return }
        pendingFiles = nil
        Task {
            // Keep security-scoped access alive until coordinated staging finishes.
            await store.importVideoFiles(selection.urls)
            withExtendedLifetime(selection) { }
        }
    }
    private func cleanupShare() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }
}

struct VideoFrame: View {
    let url: URL
    var time: Double = 0
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "video.slash") }
            else { ProgressView() }
        }
        .task(id: "\(url.absoluteString)-\(time)") {
            image = nil; failed = false
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 600, height: 600)
            do {
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                try Task.checkCancellation(); image = UIImage(cgImage: result.image)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct VideoSampleEditor: View {
    let sampleID: Int
    @EnvironmentObject private var store: ProjectStore
    @State private var player: AVPlayer?
    @State private var position = 0.0
    @State private var cropping = false
    @State private var showDelete = false
    @Environment(\.dismiss) private var dismiss
    private var sample: VideoSample? { store.project?.samples.first { $0.id == sampleID } }
    private var video: LibraryVideo? { store.project?.videos.first { $0.id == sample?.video } }
    var body: some View {
        ScrollView {
            if let sample, let video, let url = store.original(video) {
                VStack(alignment: .leading, spacing: 20) {
                    VideoPlayer(player: player).frame(minHeight: 180, maxHeight: 320)
                    HStack {
                        Button("Play selected clip", systemImage: "play.fill") { seek(sample.start); player?.play() }
                        Spacer()
                        Button("Crop", systemImage: "crop") { cropping = true }
                    }
                    VideoTrimTimeline(url: url, duration: video.duration, start: trimBinding(\.start), end: trimBinding(\.end))
                    HStack {
                        Text("Start (seconds)")
                        TextField("Start", value: trimBinding(\.start), format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        Text("End")
                        TextField("End", value: trimBinding(\.end), format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                    }
                    Slider(value: $position, in: 0...max(0.001, video.duration)) { editing in if !editing { seek(position) } }.accessibilityLabel("Scrub video")
                    let size = sample.outputSize(width: video.width, height: video.height)
                    Text("Export: \(size.width) × \(size.height) · \(sample.end - sample.start, specifier: "%.3f") seconds").font(.subheadline)
                    Text("Caption").font(.headline)
                    TextEditor(text: Binding(get: { self.sample?.caption ?? "" }, set: { value in store.editSample(sampleID) { $0.caption = value } })).frame(minHeight: 120).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    Button("Create another clip from this original", systemImage: "plus") { store.update { $0.addSample(video: video) } }
                    Button("Remove clip", role: .destructive) { showDelete = true }
                }.padding()
                .task(id: url) { player = AVPlayer(url: url); seek(sample.start) }
                .sheet(isPresented: $cropping) { VideoCropEditor(sample: sample, video: video, url: url) }
            }
        }
        .navigationTitle("Clip \(sampleID)")
        .onDisappear { player?.pause(); player = nil }
        .confirmationDialog("Remove this clip? The original video is preserved.", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Remove clip", role: .destructive) { store.update { $0.samples.removeAll { $0.id == sampleID } }; dismiss() }
        }
    }
    private func seek(_ seconds: Double) {
        player?.pause(); position = seconds
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: sample?.end ?? 0, preferredTimescale: 60000)
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func trimBinding(_ key: WritableKeyPath<VideoSample, Double>) -> Binding<Double> {
        Binding(get: { sample?[keyPath: key] ?? 0 }, set: { value in
            guard value.isFinite, let sample, let video else { return }
            let minimum = min(0.001, video.duration / 2)
            let clamped = key == \.start ? min(max(0, value), sample.end - minimum) : min(video.duration, max(sample.start + minimum, value))
            store.editSample(sampleID) { $0[keyPath: key] = clamped }
            seek(key == \.start ? clamped : sample.start)
        })
    }
}

private struct VideoTrimTimeline: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { bounds in
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) { ForEach(0..<8) { i in VideoFrame(url: url, time: duration * Double(i) / 8).frame(width: bounds.size.width / 8, height: 64).clipped() } }
                    Rectangle().fill(.black.opacity(0.5)).frame(width: bounds.size.width * start / duration)
                    Rectangle().fill(.black.opacity(0.5)).frame(width: bounds.size.width * (1 - end / duration)).offset(x: bounds.size.width * end / duration)
                    handle("Trim start", x: bounds.size.width * start / duration).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { start = $0.location.x / bounds.size.width * duration })
                    handle("Trim end", x: bounds.size.width * end / duration).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { end = $0.location.x / bounds.size.width * duration })
                }.coordinateSpace(name: "timeline")
            }.frame(height: 64)
            HStack { Text("Drag the trim handles"); Spacer(); Text("\(end - start, specifier: "%.2f") s") }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func handle(_ label: String, x: Double) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.yellow).frame(width: 18, height: 64).overlay(Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).font(.caption2).foregroundStyle(.black)).offset(x: max(0, x - 9)).accessibilityLabel(label)
    }
}

private struct VideoCropEditor: View {
    let sample: VideoSample
    let video: LibraryVideo
    let url: URL
    @State private var crop: Crop
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    init(sample: VideoSample, video: LibraryVideo, url: URL) { self.sample = sample; self.video = video; self.url = url; _crop = State(initialValue: sample.crop) }
    var body: some View {
        NavigationStack {
            Form {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        VideoFrame(url: url, time: sample.start).frame(width: geometry.size.width, height: geometry.size.height)
                        Rectangle().stroke(.yellow, lineWidth: 2).frame(width: geometry.size.width * crop.width, height: geometry.size.height * crop.height).offset(x: geometry.size.width * crop.x, y: geometry.size.height * crop.y)
                    }.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                        let a = value.startLocation, b = value.location
                        crop = Crop(x: min(a.x, b.x) / geometry.size.width, y: min(a.y, b.y) / geometry.size.height, width: abs(b.x - a.x) / geometry.size.width, height: abs(b.y - a.y) / geometry.size.height).clamped
                    })
                }.aspectRatio(CGFloat(video.width) / CGFloat(video.height), contentMode: .fit)
                cropSlider("Width", \.width, 0.01...1); cropSlider("Height", \.height, 0.01...1)
                cropSlider("Left", \.x, 0...max(0.0001, 1 - crop.width)); cropSlider("Top", \.y, 0...max(0.0001, 1 - crop.height))
                Button("Reset crop") { crop = .full }
                Text("Drag a rectangle or use the percentage sliders. The crop applies to every exported frame.").font(.caption)
            }
            .navigationTitle("Crop video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { store.editSample(sample.id) { $0.crop = crop.clamped }; dismiss() } }
            }
        }
    }
    private func cropSlider(_ title: String, _ key: WritableKeyPath<Crop, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(crop[keyPath: key] * 100))%")
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, crop[keyPath: key])) }, set: { crop[keyPath: key] = $0; crop = crop.clamped }), in: range).accessibilityLabel(title)
        }
    }
}
