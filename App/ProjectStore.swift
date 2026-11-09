import Foundation
import SwiftUI
import MakeLORACore

struct ProjectSummary: Identifiable {
    let id: UUID
    let name: String
    let count: Int
}

@MainActor final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var project: Project?
    @Published private(set) var status = "Saved on this iPad"
    @Published var error: String?
    @Published private(set) var busy = false
    let engine = ImageEngine()
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
                summaries.append(ProjectSummary(id: value.id, name: value.name, count: value.pairs.count))
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
    func create(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let value = Project(name: name)
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
    func close() { project = nil }
    func update(_ edit: (inout Project) -> Void) {
        guard var value = project, let directory else { return }
        edit(&value)
        do {
            try value.validate()
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
            project = value
            projects = projects.map { $0.id == value.id ? ProjectSummary(id: value.id, name: value.name, count: value.pairs.count) : $0 }
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
    func setImporting(_ value: Bool) { busy = value; if value { status = "Reading photos…" } }
    func retry() { scheduleGeneration() }
    func flush() async {
        generation?.cancel()
        guard let project, let directory else { return }
        revision += 1
        let current = revision
        do {
            try await engine.synchronize(project, directory: directory, revision: current)
            if revision == current { status = "Saved · JPG files up to date"; needsRetry = false }
        } catch { if revision == current { needsRetry = true; report("Update dataset files", error) } }
    }
    func export() async -> URL? {
        guard let project, let directory else { return nil }
        generation?.cancel(); revision += 1; busy = true; status = "Preparing dataset ZIP…"
        defer { busy = false }
        do {
            let url = try await engine.export(project, directory: directory, revision: revision)
            status = "Saved · JPG files up to date"; needsRetry = false
            return url
        } catch { needsRetry = true; report("Export dataset", error); return nil }
    }
    private func scheduleGeneration() {
        generation?.cancel(); revision += 1
        guard let project, let directory else { return }
        let current = revision
        status = "Saved · updating JPG files…"
        generation = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                try await engine.synchronize(project, directory: directory, revision: current)
                guard revision == current else { return }
                status = "Saved · JPG files up to date"; needsRetry = false
            } catch is CancellationError { }
            catch { guard revision == current else { return }; needsRetry = true; report("Update dataset files", error) }
        }
    }
    func report(_ operation: String, _ cause: Error) {
        error = "\(operation) failed. \(cause.localizedDescription) Check available iPad storage and the source files, then retry the operation."
        status = needsRetry ? "Dataset needs attention · tap Retry" : "Operation failed · changes may not be saved"
    }
}

extension ImageEngine {
    func waitUntilIdle() { }
}
