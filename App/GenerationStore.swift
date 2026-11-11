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
struct GenerationOutput: Codable, Identifiable {
    var id = UUID()
    let filename: String
    let model: String
    let prompt: String
    let date: Date
    var sourceKey: String? = nil
}
private struct Prediction: Decodable {
    let id: String
    let status: String
    let logs: String?
    let output: [URL]?
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
    private let session = URLSession(configuration: .ephemeral, delegate: NoPairingRedirects(), delegateQueue: nil)
    private let directory: URL
    private var pending: PendingGeneration?
    private var activeCredential: DeviceCredential?
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Generation", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = directory.appendingPathComponent("gallery.json")
            if FileManager.default.fileExists(atPath: index.path) { outputs = try JSONDecoder().decode([GenerationOutput].self, from: Data(contentsOf: index)) }
            let job = directory.appendingPathComponent("pending.json")
            if FileManager.default.fileExists(atPath: job.path) { pending = try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: job)) }
        } catch { self.error = "Could not restore generation gallery: \(error.localizedDescription)" }
    }
    func url(_ output: GenerationOutput) -> URL { directory.appendingPathComponent(output.filename) }
    private func persist() throws { try JSONEncoder().encode(outputs).write(to: directory.appendingPathComponent("gallery.json"), options: .atomic) }
    private func savePending() throws {
        // Device credentials stay in Keychain; persist only job metadata.
        guard let pending else { return }
        let data = try JSONEncoder().encode(pending)
        try data.write(to: directory.appendingPathComponent("pending.json"), options: [.atomic, .completeFileProtection])
    }
    func remove(_ output: GenerationOutput) {
        do {
            let previous = outputs
            outputs.removeAll { $0.id == output.id }
            do { try persist() } catch { outputs = previous; throw error }
            try FileManager.default.removeItem(at: url(output))
        } catch { self.error = error.localizedDescription }
    }
    private func request(_ action: String, credential: DeviceCredential, body: [String: Any]? = nil, id: String? = nil) async throws -> Data {
        var parts = URLComponents(url: credential.server.appendingPathComponent("api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "action", value: action)]
        if let id { parts.queryItems?.append(URLQueryItem(name: "id", value: id)) }
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 90
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
        models = []
        guard let credential else { return }
        do {
            struct Catalog: Decodable { let models: [GenerationModel] }
            models = try JSONDecoder().decode(Catalog.self, from: await request("models", credential: credential)).models
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
                for (index, remote) in (reply.output ?? []).enumerated() {
                    let sourceKey = job.id + ":" + String(index)
                    if outputs.contains(where: { $0.sourceKey == sourceKey }) { continue }
                    guard remote.scheme == "https" else { throw URLError(.badURL) }
                    let (data, response) = try await session.data(from: remote)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.95) else { throw URLError(.cannotDecodeContentData) }
                    let output = GenerationOutput(filename: UUID().uuidString + ".jpg", model: job.model, prompt: job.prompt, date: Date(), sourceKey: sourceKey)
                    try jpg.write(to: url(output), options: .atomic)
                    outputs.insert(output, at: 0)
                    do { try persist() } catch { outputs.removeAll { $0.id == output.id }; throw error }
                }
                try finish(); status = "Saved to gallery"; return
            }
            if ["failed", "canceled"].contains(reply.status) { try finish(); error = reply.error ?? "Generation \(reply.status)."; return }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func finish() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("pending.json")); pending = nil
    }
}
