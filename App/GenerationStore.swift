import SwiftUI
import Combine

struct GenerationModel: Decodable, Identifiable {
    let id: String
    let displayName: String
    let baseModel: String?
    let sizeBytes: Int64
    let details: String
    let supported: Bool
}
struct GenerationOutput: Decodable, Identifiable {
    let id: String
    let model: String
    let prompt: String
    let date: Date
}
private struct Prediction: Decodable {
    let id: String
    let status: String
    let logs: String?
    let error: String?
}
private struct PendingGeneration: Codable {
    let id: String
    let server: URL
    let deviceID: String
    let model: String
    let prompt: String
}
@MainActor final class GenerationStore: ObservableObject {
    @Published var models: [GenerationModel] = []
    @Published var outputs: [GenerationOutput] = []
    @Published var busy = false
    @Published var status = ""
    @Published var logs = ""
    @Published var error: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoPairingRedirects(), delegateQueue: nil)
    }()
    private let directory: URL
    private let shareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORAGenerationShares", isDirectory: true)
    private var pending: PendingGeneration?
    private var activeCredential: DeviceCredential?
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Generation", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
            // Remove only temporary share files left by a previous terminated session.
            for file in try FileManager.default.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: file)
            }
            let job = directory.appendingPathComponent("pending.json")
            if FileManager.default.fileExists(atPath: job.path) { pending = try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: job)) }
        } catch { self.error = "Could not restore generation session: \(error.localizedDescription)" }
    }
    private func savePending() throws {
        // Device credentials stay in Keychain; persist only job metadata.
        guard let pending else { return }
        let data = try JSONEncoder().encode(pending)
        try data.write(to: directory.appendingPathComponent("pending.json"), options: [.atomic, .completeFileProtection])
    }
    func remove(_ output: GenerationOutput) async -> Bool {
        guard let credential = activeCredential else { return false }
        do {
            _ = try await request("remove_output", credential: credential, body: [:], id: output.id)
            outputs.removeAll { $0.id == output.id }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func imageData(_ output: GenerationOutput) async throws -> Data {
        guard let credential = activeCredential else { throw URLError(.userAuthenticationRequired) }
        let data = try await request("output", credential: credential, id: output.id)
        guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { throw URLError(.cancelled) }
        return data
    }
    func prepareShare(_ output: GenerationOutput) async throws -> URL {
        // A temporary original exists only during the user-requested share sheet.
        let data = try await imageData(output)
        try Task.checkCancellation()
        let url = shareDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    func refreshGallery() async {
        guard let credential = activeCredential else { outputs = []; return }
        do {
            struct Gallery: Decodable { let outputs: [GenerationOutput]; let next: String? }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var collected: [GenerationOutput] = []
            var before: String?
            repeat {
                let data = try await request("gallery", credential: credential, before: before)
                let page = try decoder.decode(Gallery.self, from: data)
                collected.append(contentsOf: page.outputs); before = page.next
            } while before != nil
            guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return }
            outputs = collected
        } catch {
            outputs = [] // Never leave a gallery visible after failed access verification.
            self.error = error.localizedDescription
        }
    }
    private func request(_ action: String, credential: DeviceCredential, body: [String: Any]? = nil, id: String? = nil, before: String? = nil) async throws -> Data {
        var parts = URLComponents(url: credential.server.appendingPathComponent("api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "action", value: action)]
        if let id { parts.queryItems?.append(URLQueryItem(name: "id", value: id)) }
        if let before { parts.queryItems?.append(URLQueryItem(name: "before", value: before)) }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData); request.timeoutInterval = 90
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"] ?? "Server request failed."
            throw NSError(domain: "Generation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }
    func load(_ credential: DeviceCredential?) async {
        activeCredential = credential
        models = []; outputs = []
        guard let credential else { return }
        do {
            struct Catalog: Decodable { let models: [GenerationModel] }
            let catalog = try JSONDecoder().decode(Catalog.self, from: await request("models", credential: credential))
            guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return }
            models = catalog.models
            await refreshGallery()
        } catch { self.error = error.localizedDescription }
    }
    func generate(credential: DeviceCredential, model: GenerationModel, image: Data, prompt: String, ratio: String, scale: Double, seed: String) async {
        guard !busy, pending == nil else { error = "Resume the pending generation before starting another."; return }
        activeCredential = credential
        busy = true; error = nil; logs = ""; status = "Submitting…"
        defer { busy = false }
        do {
            var body: [String: Any] = ["model": model.id, "image": "data:image/jpeg;base64," + image.base64EncodedString(), "prompt": prompt, "aspect_ratio": ratio, "lora_scale": scale]
            if !seed.isEmpty {
                guard let value = Int(seed), (0...2147483647).contains(value) else { throw NSError(domain: "Generation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Seed must be a whole number from 0 to 2147483647."]) }
                body["seed"] = value
            }
            let reply = try JSONDecoder().decode(Prediction.self, from: await request("generate", credential: credential, body: body))
            pending = PendingGeneration(id: reply.id, server: credential.server, deviceID: credential.deviceID, model: model.displayName, prompt: prompt)
            try savePending()
            try await monitor()
        } catch { self.error = error.localizedDescription; status = pending == nil ? "Submission failed" : "Updates paused · Tap Resume" }
    }
    func resume() async {
        guard pending != nil, !busy else { return }
        busy = true; defer { busy = false }
        do { try await monitor() } catch { self.error = error.localizedDescription; status = "Updates paused · Tap Resume" }
    }
    var hasPending: Bool { pending != nil }
    private func monitor() async throws {
        guard let job = pending else { return }
        guard let credential = activeCredential, credential.server == job.server, credential.deviceID == job.deviceID else { throw NSError(domain: "Generation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reconnect to the server used for this generation."]) }
        while true {
            let reply = try JSONDecoder().decode(Prediction.self, from: await request("prediction", credential: credential, id: job.id))
            status = reply.status.capitalized; logs = reply.logs ?? ""
            if reply.status == "succeeded" {
                try finish(); status = "Saved to server gallery"
                await refreshGallery()
                return
            }
            if ["failed", "canceled"].contains(reply.status) { try finish(); error = reply.error ?? "Generation \(reply.status)."; return }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func finish() throws {
        let file = directory.appendingPathComponent("pending.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        pending = nil
    }
}
