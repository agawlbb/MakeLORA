import Foundation
import CryptoKit
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
    let model: String
    var destination: FileBeansLocation? = nil
    let videos: [ServerDatasetVideo]
    let clips: [ServerDatasetClip]
    let exportStatus: String
    let exportError: String?
    let exportURL: URL?
    var exportFolder: String? = nil
    var exportDestination: String? = nil
    var processing: Bool { videos.contains { ["queued", "processing"].contains($0.status) } || ["queued", "processing"].contains(exportStatus) }
}
struct ServerDatasetVideo: Decodable, Identifiable {
    let id: String
    let source: String
    let path: String
    let revision: String
    var reviewRequired: Bool? = nil
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
    var videoID: String = ""
    var start: Double
    var end: Double
    var caption: String
    var crop: ServerDatasetCrop?
    var control: String? = nil
    var target: String? = nil
    var controlCrop: ServerDatasetCrop? = nil
    var targetCrop: ServerDatasetCrop? = nil
    enum CodingKeys: String, CodingKey { case id, videoID, start, end, caption, crop, control, target, controlCrop, targetCrop }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); videoID = try c.decodeIfPresent(String.self, forKey: .videoID) ?? ""
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        caption = try c.decode(String.self, forKey: .caption); crop = try c.decodeIfPresent(ServerDatasetCrop.self, forKey: .crop)
        control = try c.decodeIfPresent(String.self, forKey: .control); target = try c.decodeIfPresent(String.self, forKey: .target)
        controlCrop = try c.decodeIfPresent(ServerDatasetCrop.self, forKey: .controlCrop); targetCrop = try c.decodeIfPresent(ServerDatasetCrop.self, forKey: .targetCrop)
    }
    init(id: String, videoID: String = "", start: Double = 0, end: Double = 0, caption: String = "", crop: ServerDatasetCrop? = nil, control: String? = nil, target: String? = nil, controlCrop: ServerDatasetCrop? = nil, targetCrop: ServerDatasetCrop? = nil) {
        self.id=id; self.videoID=videoID; self.start=start; self.end=end; self.caption=caption; self.crop=crop
        self.control=control; self.target=target; self.controlCrop=controlCrop; self.targetCrop=targetCrop
    }
    static func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
struct FileBeansLocation: Codable, Hashable {
    var source: String
    var path: String
}
struct FileBeansEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let type: String
    let revision: String
    let size: Int64
    var children: [FileBeansEntry]?
    var id: String { path }
    var isFolder: Bool { type == "directory" }
}
struct FileBeansScope: Decodable, Identifiable { let name: String; var id: String { name } }
struct FileBeansConnection: Decodable {
    let configured: Bool
    let connected: Bool
    let workerReady: Bool?
    let managementURL: URL?
}
private struct DatasetServiceError: Decodable, LocalizedError {
    let error: String
    var errorDescription: String? { error }
}

@MainActor final class ServerDatasetStore: ObservableObject {
    @Published var projects: [ServerDatasetSummary] = []
    @Published var project: ServerDataset?
    @Published var connection: FileBeansConnection?
    @Published var busy = false
    @Published var error: String?
    private(set) var credential: DeviceCredential?
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoPairingRedirects(), delegateQueue: nil)
    }

    func configure(_ value: DeviceCredential?) {
        if credential?.server != value?.server || credential?.deviceID != value?.deviceID || credential?.token != value?.token {
            project = nil; projects = []; connection = nil; error = nil
        }
        credential = value
    }
    var managementURL: URL? { connection?.managementURL ?? credential?.server.appendingPathComponent("filebeans.php") }
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
        connection = try JSONDecoder().decode(FileBeansConnection.self, from: await request("dataset_connection"))
    }
    func open(_ id: String) async throws {
        let result = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: id))
        project = result
        try await activity(force: true)
    }
    func poll(_ id: String) async {
        do {
            let result = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset", id: id))
            guard project?.id == id else { return }; project = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func create(_ name: String, model: String) async throws {
        project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_create", body: ["name": name, "model": model]))
        try await refresh()
    }
    private var lastActivity = Date.distantPast
    func activity(force: Bool = false) async throws {
        guard let project, force || Date().timeIntervalSince(lastActivity) >= 30 else { return }
        lastActivity = Date()
        do { _ = try await request("dataset_activity", id: project.id, body: [:]) }
        catch { lastActivity = .distantPast; throw error }
    }
    func noteActivity() { Task { do { try await activity() } catch { self.error = error.localizedDescription } } }
    func scopes() async throws -> [FileBeansScope] {
        struct Reply: Decodable { let scopes: [FileBeansScope] }
        return try JSONDecoder().decode(Reply.self, from: await request("dataset_sources")).scopes
    }
    func browse(_ location: FileBeansLocation) async throws -> FileBeansEntry {
        try JSONDecoder().decode(FileBeansEntry.self, from: await request("dataset_files", query: location.query))
    }
    func importSources(_ locations: [FileBeansLocation]) async throws {
        guard let project else { return }
        let files = locations.map { ["id": ServerDatasetClip.identifier(), "source": $0.source, "path": $0.path] }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_import", id: project.id, body: ["files": files]))
    }
    func retrySource(_ id: String) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_retry_source", id: project.id, query: [URLQueryItem(name: "video", value: id)], body: [:]))
    }
    func relink(_ id: String, to location: FileBeansLocation) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_relink", id: project.id, body: ["video": id, "location": ["source": location.source, "path": location.path]]))
    }
    func upload(_ file: URL, to location: FileBeansLocation) async throws {
        guard let credential else { throw URLError(.userAuthenticationRequired) }
        var parts = URLComponents(url: credential.server.appendingPathComponent("api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "action", value: "dataset_upload")] + location.query
        var req = URLRequest(url: parts.url!); req.httpMethod = "POST"; req.timeoutInterval = 3600
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let digest = try await Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        let identity = credential.deviceID + location.source + location.path + digest
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        req.setValue(digest, forHTTPHeaderField: "X-Content-SHA256"); req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        let (data, response) = try await session.upload(for: req, fromFile: file)
        try Task.checkCancellation()
        guard self.credential?.token == credential.token else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw (try? JSONDecoder().decode(DatasetServiceError.self, from: data)) ?? DatasetServiceError(error: "Upload failed. Choose another name or folder and retry.")
        }
    }
    func cancelExport() async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_cancel_export", id: project.id, body: [:]))
    }
    func save(_ clips: [ServerDatasetClip], name: String? = nil, revision: Int, reviewedSources: [String] = []) async throws {
        guard let project else { return }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clips))
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_save", id: project.id, body: ["clips": encoded, "name": name ?? project.name, "revision": revision, "reviewedSources": reviewedSources]))
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
        try await save(clips, revision: latest.revision, reviewedSources: [clip.control, clip.target].compactMap { $0 })
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
        let saved = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_save", id: projectID, body: ["name": latest.name, "revision": latest.revision, "clips": encoded, "reviewedSources": [videoID]]))
        guard project?.id == projectID else { throw CancellationError() }
        project = saved
        return VideoEditSaveResult(clips: saved.clips.filter { $0.videoID == videoID }.map(\.editorClip))
    }
    func setDestination(_ location: FileBeansLocation) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_destination", id: project.id, body: ["destination": ["source": location.source, "path": location.path]]))
    }
    func export(to location: FileBeansLocation) async throws {
        guard let project else { return }
        self.project = try JSONDecoder().decode(ServerDataset.self, from: await request("dataset_export", id: project.id, body: ["destination": ["source": location.source, "path": location.path]]))
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

extension FileBeansLocation {
    var query: [URLQueryItem] { [URLQueryItem(name: "source", value: source), URLQueryItem(name: "path", value: path)] }
    func appending(_ name: String) -> FileBeansLocation { FileBeansLocation(source: source, path: (path == "/" ? "" : path) + "/" + name) }
}
