import SwiftUI
import AVKit
import MakeLORACore

private enum VideoEditorTab: String, CaseIterable { case trim = "Trim", crop = "Crop", caption = "Caption", clips = "Clips" }

struct VideoClipEditorWorkspace: View {
    let name: String
    let duration: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let refresh: (() async throws -> VideoEditorMedia)?
    let saveEdits: ([VideoEditingClip], [VideoEditingClip]) async throws -> VideoEditSaveResult
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = VideoEditorPlayback()
    @State private var session: VideoEditingSession
    @State private var media: VideoEditorMedia
    @State private var tab = VideoEditorTab.trim
    @State private var shape = VideoCropShape.free
    @State private var previewCrop = false
    @State private var saving = false
    @State private var refreshing = false
    @State private var notice: String?
    @State private var error: String?
    @State private var playbackError: String?
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    init(name: String, duration: Double, width: Int, height: Int, media: VideoEditorMedia, clips: [VideoEditingClip], selectedID: String?, newClipAt: Double? = nil, refresh: (() async throws -> VideoEditorMedia)? = nil, save: @escaping ([VideoEditingClip], [VideoEditingClip]) async throws -> VideoEditSaveResult) {
        self.name = name; self.duration = duration; sourceWidth = width; sourceHeight = height; self.refresh = refresh; saveEdits = save
        var initial = VideoEditingSession(duration: duration, clips: clips, selectedID: selectedID)
        if let time = newClipAt { initial.add(at: time) }
        else if initial.clips.isEmpty { initial.add(at: 0) }
        _session = State(initialValue: initial); _media = State(initialValue: media)
    }
    private var sourceAspect: Double { Double(sourceWidth)/Double(sourceHeight) }
    private var selected: VideoEditingClip? { session.selected }
    private var crop: Crop { selected?.crop ?? .full }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width >= 850 && geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        previewPane.padding(16).frame(maxWidth: .infinity)
                        Divider()
                        controls.frame(width: min(390, geometry.size.width*0.38))
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPane.padding(.horizontal, 12).padding(.top, 8)
                            .frame(height: min(max(210, geometry.size.height*0.60), geometry.size.width/sourceAspect+160))
                        Divider()
                        controls.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { leave() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save all") { save() }.disabled(saving || !session.hasChanges) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide keyboard") { hideKeyboard() } }
            }
            .disabled(saving)
            .interactiveDismissDisabled(session.hasChanges || saving)
            .confirmationDialog("Save your clip changes before closing?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Save and close") { save(close: true) }
                Button("Discard unsaved changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            }
            .confirmationDialog("Remove this clip? The source video and other clips are kept. Save all to apply the removal.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove clip", role: .destructive) { session.removeSelected(); tab = session.selected == nil ? .clips : .trim; selectedChanged() }
            }
            .onAppear { playback.load(media.url, at: selected?.start ?? 0) }
            .onDisappear { playback.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause() } }
            .onChange(of: tab) { _, value in if value == .crop { playback.pause() }; hideKeyboard() }
            .task(id: playback.player.map { ObjectIdentifier($0) }) { await monitorPlayback() }
        }
    }
    private var previewPane: some View {
        VStack(spacing: 8) {
            GeometryReader { bounds in
                let aspect = previewCrop ? sourceAspect*crop.width/crop.height : sourceAspect
                let size = VideoCropGeometry.fitted(aspect: aspect, width: bounds.size.width, height: bounds.size.height)
                ZStack {
                    Color.black
                    ZStack(alignment: .topLeading) {
                        if previewCrop {
                            VideoEditorSurface(player: playback.player)
                                .frame(width: size.width/crop.width, height: size.height/crop.height)
                                .offset(x: -crop.x*size.width/crop.width, y: -crop.y*size.height/crop.height)
                        } else {
                            VideoEditorSurface(player: playback.player).frame(width: size.width, height: size.height)
                        }
                    }.frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
                        .overlay {
                            if !previewCrop && tab == .crop && selected != nil {
                                VideoEditorCropOverlay(crop: cropBinding, normalizedAspect: shape.aspect(source: sourceAspect).map { $0/sourceAspect }, interacting: { playback.pause(); notice = nil })
                            }
                        }
                }.accessibilityLabel(previewCrop ? "Cropped video preview" : "Source video preview")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            playbackButtons
            VideoEditorTimeline(media: media, duration: duration, hasSelection: selected != nil, start: startBinding, end: endBinding, position: positionBinding)
        }
    }
    private var playbackButtons: some View {
        HStack(spacing: 12) {
            Button { if playback.playing { playback.pause() } else if let selected { playback.play(start: selected.start, end: selected.end) } }
                label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 32, height: 28) }
                .accessibilityLabel(playback.playing ? "Pause video" : "Play selected clip").disabled(selected == nil)
            Text(videoEditorTime(playback.position)).font(.caption.monospacedDigit())
            Spacer(minLength: 4)
            Button { previewCrop.toggle() } label: { Label(previewCrop ? "Original" : "Preview crop", systemImage: "crop") }.font(.caption).disabled(selected == nil)
        }
    }
    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedTitle).font(.headline)
                Spacer()
                Button("Add clip", systemImage: "plus") { addClip() }.font(.subheadline)
            }.padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal).padding(.bottom, 8) }
            Picker("Video editor controls", selection: $tab) { ForEach(VideoEditorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice { Text(notice).foregroundStyle(.secondary).font(.callout) }
                    if let playbackError { Text(playbackError).foregroundStyle(.orange).font(.callout) }
                    if let refresh {
                        Button(refreshing ? "Refreshing…" : "Refresh streaming preview", systemImage: "arrow.clockwise") { refreshPreview(refresh) }.font(.caption).disabled(refreshing)
                    }
                    if let selected {
                        switch tab {
                        case .trim: trimControls(selected)
                        case .crop: cropControls
                        case .caption: captionControls
                        case .clips: clipList
                        }
                    } else { clipList }
                }.padding()
            }.scrollDismissesKeyboard(.interactively)
        }
    }
    private func trimControls(_ clip: VideoEditingClip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag the two timeline handles independently. The white playhead only changes the frame you’re viewing.").font(.callout).foregroundStyle(.secondary)
            HStack { Text("Start · seconds"); Spacer(); TextField("Start seconds", value: startBinding, format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(maxWidth: 130) }
            HStack { Button("−0.1 s") { startBinding.wrappedValue -= 0.1 }; Button("Set start here") { startBinding.wrappedValue = playback.position }; Button("+0.1 s") { startBinding.wrappedValue += 0.1 } }.font(.caption).buttonStyle(.bordered)
            HStack { Text("End · seconds"); Spacer(); TextField("End seconds", value: endBinding, format: .number.precision(.fractionLength(3))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(maxWidth: 130) }
            HStack { Button("−0.1 s") { endBinding.wrappedValue -= 0.1 }; Button("Set end here") { endBinding.wrappedValue = playback.position }; Button("+0.1 s") { endBinding.wrappedValue += 0.1 } }.font(.caption).buttonStyle(.bordered)
            Text(String(format: "Clip length: %.3f seconds", clip.end-clip.start)).monospacedDigit()
            Slider(value: positionBinding, in: 0...duration).accessibilityLabel("Source video playhead")
            Button("Save and add another clip", systemImage: "plus.rectangle.on.rectangle") { save(addAnother: true) }.buttonStyle(.borderedProminent)
            Text("Saves every draft clip. The next short selection starts at this clip’s end. Overlapping clips are also allowed.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(previewCrop ? "Showing the area that will be exported. Select Original below to adjust the crop." : "Drag a yellow corner to resize. Drag inside the box to move it. The shaded area is removed.").font(.callout)
            Picker("Crop shape", selection: $shape) { ForEach(VideoCropShape.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu)
                .onChange(of: shape) { _, value in
                    session.edit { $0.crop = VideoCropGeometry.preset(value, sourceAspect: sourceAspect, around: $0.crop) }
                    previewCrop = false; playback.pause(); notice = nil
                }
            HStack {
                Button("Reset crop") { session.edit { $0.crop = .full }; shape = .free; previewCrop = false }
                Spacer()
                Button(previewCrop ? "Show original" : "Preview crop") { previewCrop.toggle() }
            }.buttonStyle(.bordered)
            Text(outputDescription).font(.callout).monospacedDigit()
            Text("This crop applies to every frame of this clip. Other clips keep their own crops.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var captionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caption for this clip").font(.headline)
            TextEditor(text: Binding(get: { selected?.caption ?? "" }, set: { value in session.edit { $0.caption = value }; notice = nil }))
                .frame(minHeight: 150).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Clip caption")
            Text("Each clip has its own caption. Switching clips keeps your drafts until you save or discard them.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var clipList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.clips.count) clips from this source").font(.headline)
            ForEach(Array(session.clips.enumerated()), id: \.element.id) { index, clip in
                Button { session.selectedID = clip.id; selectedChanged(); tab = .trim } label: {
                    HStack {
                        Image(systemName: clip.id == session.selectedID ? "checkmark.circle.fill" : "film")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clip \(index+1)\(session.baseline.contains(clip) ? "" : " · unsaved")").font(.headline)
                            Text("\(videoEditorTime(clip.start))–\(videoEditorTime(clip.end))").font(.caption.monospacedDigit())
                            Text(clip.caption.isEmpty ? "No caption" : clip.caption).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            if session.clips.isEmpty { Text("The source video is still available. Add a clip at the playhead to start a new selection.").foregroundStyle(.secondary) }
            if selected != nil {
                Button("Duplicate selected clip", systemImage: "plus.square.on.square") { session.duplicate(); selectedChanged(); tab = .trim }.buttonStyle(.bordered)
                Button("Remove selected clip", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
    }
    private var selectedTitle: String {
        guard let index = session.clips.firstIndex(where: { $0.id == session.selectedID }) else { return "Source clips" }
        return "Clip \(index+1)"
    }
    private var outputDescription: String {
        let width = Double(sourceWidth)*crop.width, height = Double(sourceHeight)*crop.height
        let scale = 480/min(width,height)
        return "Export: \(Int((width*scale/2).rounded())*2) × \(Int((height*scale/2).rounded())*2) · 480p"
    }
    private var startBinding: Binding<Double> { Binding(get: { selected?.start ?? 0 }, set: { value in session.setStart(value); playback.seek(selected?.start ?? 0); notice = nil }) }
    private var endBinding: Binding<Double> { Binding(get: { selected?.end ?? duration }, set: { value in session.setEnd(value); playback.seek(max(selected?.start ?? 0, (selected?.end ?? duration)-0.033)); notice = nil }) }
    private var positionBinding: Binding<Double> { Binding(get: { min(duration,max(0,playback.position)) }, set: { playback.seek(min(duration,max(0,$0))) }) }
    private var cropBinding: Binding<Crop> { Binding(get: { crop }, set: { value in session.edit { $0.crop = value }; notice = nil }) }
    private func selectedChanged() { shape = .free; previewCrop = false; notice = nil; error = nil; hideKeyboard(); playback.seek(selected?.start ?? playback.position) }
    private func addClip() { hideKeyboard(); session.add(at: playback.position); selectedChanged(); tab = .trim }
    private func leave() { hideKeyboard(); playback.pause(); if session.hasChanges { confirmLeave = true } else { dismiss() } }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    private func save(close: Bool = false, addAnother: Bool = false) {
        guard !saving else { return }
        hideKeyboard(); playback.pause(); error = nil
        let nextStart = selected?.end ?? playback.position
        if !session.hasChanges {
            if close { dismiss() }
            else if addAnother { beginNextClip(at: nextStart) }
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                for (index, clip) in session.clips.enumerated() {
                    guard clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.end > clip.start, clip.end <= duration else { throw ProjectError.invalid("Clip \(index+1): choose start and end times inside the source video.") }
                    let aspect = sourceAspect*clip.crop.width/clip.crop.height
                    guard aspect >= 1.0/16 && aspect <= 16 else { throw ProjectError.invalid("Clip \(index+1): the crop is too narrow to export. Choose a wider crop or a preset shape.") }
                }
                let result = try await saveEdits(session.baseline, session.clips)
                session.accept(result); notice = "Saved \(result.clips.count) clips from this source."
                if close { dismiss() }
                else if addAnother { beginNextClip(at: nextStart) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func beginNextClip(at time: Double) {
        if session.add(at: time, fallbackToBeginning: false) { selectedChanged(); tab = .trim }
        else { notice = "Saved. You’re at the end of the source. Move the playhead earlier and select Add clip to make an overlapping clip." }
    }
    private func refreshPreview(_ action: @escaping () async throws -> VideoEditorMedia) {
        refreshing = true; playbackError = nil
        Task {
            defer { refreshing = false }
            do { let value = try await action(); media = value; playback.load(value.url, at: playback.position) }
            catch { playbackError = error.localizedDescription }
        }
    }
    private func monitorPlayback() async {
        guard let player = playback.player else { return }
        var waiting = 0
        while !Task.isCancelled {
            if player.currentItem?.status == .failed { playbackError = "The preview could not be played. Check your connection and refresh the preview."; return }
            if player.currentItem?.status == .unknown || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waiting += 1 } else { waiting = 0 }
            if waiting == 30 { playbackError = "The preview is taking longer than expected. Check your connection or refresh its link." }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
}
