import Foundation
import SwiftUI
import MakeLORACore

struct ProjectSummary: Identifiable {
    let id: UUID
    let name: String
    let count: Int
    let model: DatasetModel
}

@MainActor final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var project: Project?
    @Published private(set) var status = "Saved on this device"
    @Published var error: String?
    @Published private(set) var busy = false
    let engine = ImageEngine()
    let videoEngine = VideoEngine()
    @Published private(set) var progress: Double = 0
    private var exportTask: Task<URL, Error>?
    @Published private(set) var cancelRequested = false
    private var videoImportTask: Task<LibraryVideo, Error>?
    private let root: URL
    private var generation: Task<Void, Never>?
    private var revision = 0
    private var needsRetry = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects", isDirectory: true)
        do { try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true); try refresh() }
        catch { report("Open project library", error) }
    }
    var directory: URL? { project.map { root.appendingPathComponent($0.id.uuidString, isDirectory: true) } }
    func original(_ photo: LibraryPhoto) -> URL? { directory?.appendingPathComponent("originals/\(photo.filename)") }

    private func refresh() throws {
        var summaries: [ProjectSummary] = []
        var unreadable: [String] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            do {
                let value = try load(directory)
                summaries.append(ProjectSummary(id: value.id, name: value.name, count: value.sampleCount, model: value.model))
            } catch { unreadable.append(directory.lastPathComponent) }
        }
        projects = summaries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !unreadable.isEmpty { error = "Cannot open \(unreadable.count) project(s) because their saved data is unreadable. Their files have been preserved. Restore a valid device backup to recover them. Project IDs: \(unreadable.joined(separator: ", "))." }
    }
    private func load(_ directory: URL) throws -> Project {
        let value = try JSONDecoder().decode(Project.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
        try value.validate()
        guard value.id.uuidString == directory.lastPathComponent else { throw ProjectError.invalid("Project identity does not match its folder.") }
        return value
    }
    func create(name: String, model: DatasetModel = .qwenImageEdit2509) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let value = Project(name: name, model: model)
        let directory = root.appendingPathComponent(value.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
            project = value; try refresh(); scheduleGeneration()
        } catch { report("Create project", error) }
    }
    func open(_ summary: ProjectSummary) {
        do {
            let value = try load(root.appendingPathComponent(summary.id.uuidString))
            project = value; scheduleGeneration()
        } catch { report("Open \(summary.name)", error) }
    }
    func close() {
        generation?.cancel()
        guard let snapshot = project, let directory else { project = nil; return }
        revision += 1
        let current = revision
        project = nil
        Task {
            do { try await synchronize(snapshot, directory: directory, revision: current) }
            catch { report("Update dataset for \(snapshot.name)", error) }
        }
    }
    func update(_ edit: (inout Project) -> Void) {
        guard var value = project, let directory else { return }
        edit(&value)
        do {
            try value.validate()
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
            project = value
            projects = projects.map { $0.id == value.id ? ProjectSummary(id: value.id, name: value.name, count: value.sampleCount, model: value.model) : $0 }
            scheduleGeneration()
        } catch { report("Save project changes", error) }
    }
    func editPair(_ id: Int, _ edit: (inout ImagePair) -> Void) {
        update { value in if let index = value.pairs.firstIndex(where: { $0.id == id }) { edit(&value.pairs[index]) } }
    }
    func deleteProject() {
        guard let project, let directory else { return }
        generation?.cancel()
        busy = true
        Task {
            // Wait for queued image work before removing its inputs and outputs.
            await engine.waitUntilIdle()
            await videoEngine.waitUntilIdle()
            do {
                try FileManager.default.removeItem(at: directory)
                self.project = nil; projects.removeAll { $0.id == project.id }
            } catch { report("Delete project", error) }
            busy = false
        }
    }
    func importPhotos(_ inputs: [(Data, String)]) async {
        guard let directory, let id = project?.id else { return }
        busy = true; status = "Importing photos…"
        var failures: [String] = []
        for (data, name) in inputs {
            if cancelRequested { break }
            do {
                let photo = try await engine.importPhoto(data: data, name: name, directory: directory)
                guard project?.id == id else { break }
                update { $0.photos.append(photo) }
                // If saving the manifest failed, leave the original intact for recovery.
            } catch { failures.append(error.localizedDescription) }
        }
        busy = false
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        scheduleGeneration()
    }
    func setImporting(_ value: Bool) { busy = value; if value { status = project?.model == .wan21I2V14B ? "Reading videos…" : "Reading photos…" } }
    func beginImport() { cancelRequested = false; progress = 0; setImporting(true) }
    func retry() { scheduleGeneration() }
    func flush() async {
        generation?.cancel()
        guard let project, let directory else { return }
        revision += 1
        let current = revision
        do {
            try await synchronize(project, directory: directory, revision: current)
            if revision == current { status = "Saved · dataset files up to date"; needsRetry = false }
        } catch { if revision == current { needsRetry = true; report("Update dataset files", error) } }
    }
    func export() async -> URL? {
        guard let project, let directory else { return nil }
        generation?.cancel(); revision += 1; busy = true; status = "Preparing dataset ZIP…"
        defer { busy = false }
        do {
            let current = revision
            progress = 0
            let task = Task<URL, Error> {
                if project.model == .wan21I2V14B {
                    return try await videoEngine.export(project, directory: directory, revision: current) { fraction in
                        Task { @MainActor in
                            if self.revision == current, self.project?.id == project.id { self.progress = fraction }
                        }
                    }
                }
                return try await engine.export(project, directory: directory, revision: current)
            }
            exportTask = task
            defer { exportTask = nil }
            let url = try await task.value
            status = "Saved · dataset files up to date"; needsRetry = false
            return url
        } catch is CancellationError { status = "Export canceled · edits saved"; return nil }
        catch { needsRetry = true; report("Export dataset", error); return nil }
    }
    private func scheduleGeneration() {
        generation?.cancel(); revision += 1
        guard let project, let directory else { return }
        let current = revision
        if busy { return }
        status = "Saved · updating dataset files…"
        generation = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                try await synchronize(project, directory: directory, revision: current)
                guard revision == current else { return }
                status = "Saved · dataset files up to date"; needsRetry = false
            } catch is CancellationError { }
            catch { guard revision == current else { return }; needsRetry = true; report("Update dataset files", error) }
        }
    }
    func cancelWork() { cancelRequested = true; exportTask?.cancel(); videoImportTask?.cancel(); generation?.cancel() }
    func original(_ video: LibraryVideo) -> URL? { directory?.appendingPathComponent("originals/\(video.filename)") }
    func editSample(_ id: Int, _ edit: (inout VideoSample) -> Void) {
        update { value in if let i = value.samples.firstIndex(where: { $0.id == id }) { edit(&value.samples[i]) } }
    }
    func importVideos(_ urls: [URL], captions: [String: String] = [:]) async {
        guard let directory, let id = project?.id else { return }
        if !busy { cancelRequested = false }
        generation?.cancel(); busy = true; status = "Importing videos…"
        defer {
            busy = false
            if cancelRequested { status = "Import canceled · edits saved" }
            else { scheduleGeneration() }
        }
        for url in urls {
            if cancelRequested { break }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                let task = Task { try await videoEngine.importVideo(url: url, name: url.lastPathComponent, directory: directory) }
                videoImportTask = task
                defer { videoImportTask = nil }
                let video = try await task.value
                guard project?.id == id else { return }
                update {
                    $0.videos.append(video)
                    $0.addSample(video: video, caption: captions[url.deletingPathExtension().lastPathComponent] ?? "")
                }
            } catch is CancellationError { break }
            catch { report("Import \(url.lastPathComponent)", error) }
        }
    }
    private func synchronize(_ value: Project, directory: URL, revision: Int) async throws {
        if value.model == .wan21I2V14B { try await videoEngine.synchronize(value, directory: directory, revision: revision) }
        else { try await engine.synchronize(value, directory: directory, revision: revision) }
    }
    func report(_ operation: String, _ cause: Error) {
        error = "\(operation) failed. \(cause.localizedDescription) Check available device storage and the source files, then retry the operation."
        status = needsRetry ? "Dataset needs attention · tap Retry" : "Operation failed · changes may not be saved"
    }
}

extension ImageEngine {
    func waitUntilIdle() { }
}
