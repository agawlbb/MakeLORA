import Foundation
import Combine
import MakeLORACore

struct ServerDatasetSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let count: Int
}
struct ServerDataset: Decodable, Identifiable {
    let id: String
    var name: String
    let revision: Int
    let videos: [ServerDatasetVideo]
    let clips: [ServerDatasetClip]
    let exportStatus: String
    let exportError: String?
    let exportURL: URL?
    var processing: Bool { videos.contains { ["queued", "processing"].contains($0.status) } || ["queued", "processing"].contains(exportStatus) }
}
struct ServerDatasetVideo: Decodable, Identifiable {
    let id: String
    let driveID: String
    let name: String
    let status: String
    let error: String?
    let duration: Double?
    let width: Int?
    let height: Int?
    let previewURL: URL?
    let thumbnails: [URL]?
}
struct ServerDatasetCrop: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
}
struct ServerDatasetClip: Codable, Identifiable, Equatable {
    var id: String
    var videoID: String
    var start: Double
    var end: Double
    var caption: String
    var crop: ServerDatasetCrop?
    static func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
struct DriveFile: Decodable, Identifiable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}
struct DriveListing: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}
struct DriveConnection: Decodable {
    let configured: Bool
    let connected: Bool
    let workerReady: Bool?
}
private struct DatasetServiceError: Decodable, LocalizedError {
    let error: String
    var errorDescription: String? { error }
}

@MainActor final class ServerDatasetStore: ObservableObject {
    @Published var projects: [ServerDatasetSummary] = []
    @Published var project: ServerDataset?
    @Published var connection: DriveConnection?
    @Published var busy = false
    @Published var error: String?
    private(set) var credential: DeviceCredential?
    private let session = URLSession(configuration: .ephemeral, delegate: NoPairingRedirects(), delegateQueue: nil)

    func configure(_ value: DeviceCredential?) {
        if credential?.server != value?.server || credential?.deviceID != value?.deviceID || credential?.token != value?.token {
            project = nil; projects = []; connection = nil; error = nil
        }
        credential = value
    }
    var managementURL: URL? { credential?.server.appendingPathComponent("drive.php") }
    private func request(_ action: String, id: String? = nil, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        guard let credential else { throw URLError(.userAuthenticationRequired) }
        var parts = URLComponents(url: credential.server.appendingPathComponent("api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "action", value: action)] + query
        if let id { parts.queryItems?.append(URLQueryItem(name: "id", value: id)) }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 60
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard self.credential?.server == credential.server, self.credential?.token == credential.token else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw (try? JSONDecoder().decode(DatasetServiceError.self, from: data)) ?? DatasetServiceError(error: "The server could not complete this request. Check its connection and try again.")
        }
        return data
    }
    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do { try await action() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async throws {
        struct Reply: Decodable { let projects: [ServerDatasetSummary] }
        projects = try JSONDecoder().decode(Reply.self, from: await request("datasets")).projects
        connection = try JSONDecoder().decode(DriveConnection.self, from: await request("drive_status"))
    }
    func open(_ id: String) async throws {
        let result = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: id))
        project = result
    }
    func poll(_ id: String) async {
        do {
            let result = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: id))
            guard project?.id == id else { return }; project = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func create(_ name: String) async throws {
        project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_create", body: ["name": name]))
        try await refresh()
    }
    func browse(_ folder: String, page: String? = nil) async throws -> DriveListing {
        try JSONDecoder().decode(DriveListing.self, from: await request("drive_files", query: [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "page", value: page ?? "")]))
    }
    func importVideos(_ ids: Set<String>) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_import", id: project.id, body: ["files": Array(ids).sorted()]))
    }
    func save(_ clips: [ServerDatasetClip], name: String? = nil, revision: Int) async throws {
        guard let project else { return }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clips))
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_save", id: project.id, body: ["clips": encoded, "name": name ?? project.name, "revision": revision]))
    }
    func saveClip(_ clip: ServerDatasetClip, original: ServerDatasetClip?, projectID: String) async throws {
        let latest = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: projectID))
        guard latest.clips.first(where: { $0.id == clip.id }) == original else {
            throw DatasetServiceError(error: "This clip changed on another device. Reopen the editor to load its latest settings.")
        }
        guard project?.id == projectID else { throw CancellationError() }
        project = latest
        var clips = latest.clips.filter { $0.id != clip.id }
        if let index = latest.clips.firstIndex(where: { $0.id == clip.id }) { clips.insert(clip, at: index) }
        else { clips.append(clip) }
        try await save(clips, revision: latest.revision)
    }
    func saveSourceClips(projectID: String, videoID: String, baseline: [VideoEditingClip], edited: [VideoEditingClip]) async throws -> VideoEditSaveResult {
        let latest = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: projectID))
        guard project?.id == projectID, latest.videos.contains(where: { $0.id == videoID && $0.status == "ready" }) else { throw URLError(.resourceUnavailable) }
        let source = latest.clips.filter { $0.videoID == videoID }
        let merged = try VideoClipChanges.merge(baseline: baseline, edited: edited, current: source.map(\.editorClip))
        let replacements = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        var clips = latest.clips.compactMap { clip -> ServerDatasetClip? in
            guard clip.videoID == videoID else { return clip }
            return replacements[clip.id].map { ServerDatasetClip(editor: $0, videoID: videoID) }
        }
        let previous = Set(source.map(\.id))
        clips += merged.filter { !previous.contains($0.id) }.map { ServerDatasetClip(editor: $0, videoID: videoID) }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clips))
        let saved = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_save", id: projectID, body: ["name": latest.name, "revision": latest.revision, "clips": encoded]))
        guard project?.id == projectID else { throw CancellationError() }
        project = saved
        return VideoEditSaveResult(clips: saved.clips.filter { $0.videoID == videoID }.map(\.editorClip))
    }
    func export() async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_export", id: project.id, body: [:]))
    }
    func removeVideo(_ id: String) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_remove_video", id: project.id, query: [URLQueryItem(name: "video", value: id)], body: [:]))
    }
    func delete() async throws {
        guard let project else { return }
        _ = try await request("dataset_delete", id: project.id, body: [:])
        self.project = nil; try await refresh()
    }
}

extension ServerDatasetClip {
    var editorClip: VideoEditingClip {
        VideoEditingClip(id: id, start: start, end: end, caption: caption, crop: crop.map { Crop(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .full)
    }
    init(editor: VideoEditingClip, videoID: String) {
        self.init(id: editor.id, videoID: videoID, start: editor.start, end: editor.end, caption: editor.caption, crop: editor.crop == .full ? nil : ServerDatasetCrop(x: editor.crop.x, y: editor.crop.y, width: editor.crop.width, height: editor.crop.height))
    }
}
