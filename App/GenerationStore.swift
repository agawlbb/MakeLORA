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
struct GenerationSettings: Decodable {
    let modelID: String?
    let modelName: String
    let baseModel: String?
    let prompt: String
    let aspectRatio: String?
    let loraScale: Double?
    let seed: Int?
    let outputFormat: String?
    let disableSafetyChecker: Bool?
    let retryOffline: Bool?
}
struct GenerationDetails: Decodable {
    let legacy: Bool
    let settings: GenerationSettings
    let hasInput: Bool
    let resolvedSeed: Int?
}
struct GenerationDraft: Identifiable {
    let id = UUID()
    let output: GenerationOutput
    let details: GenerationDetails
    func matchingModel(in models: [GenerationModel]) -> GenerationModel? {
        if let id = details.settings.modelID { return models.first { $0.id == id } }
        guard details.legacy else { return nil }
        let matches = models.filter { $0.displayName == details.settings.modelName }
        return matches.count == 1 ? matches.first : nil
    }
}
struct GenerationJob: Decodable, Identifiable {
    let id: String
    let model: String
    let prompt: String
    var status: String
    var latestStatus: String
    var retryEnabled: Bool? = nil
    var nextRetryAt: Date? = nil
    var retryUntil: Date? = nil
    var retryCount: Int? = nil
    var canCancelRetries: Bool? = nil
    var isProcessing: Bool { ["submitting", "starting", "processing", "retry_submitting"].contains(status) }
}
private struct Prediction: Decodable {
    let id: String
    let status: String
    let latestStatus: String?
    let error: String?
    let retryAfter: Int?
}
enum GenerationSubmissionOutcome { case submitted, failed, sourceUnavailable }
private struct GenerationServiceError: Decodable, LocalizedError {
    var httpStatus: Int? = nil
    let error: String
    let retryAfter: Int?
    let jobID: String?
    let jobStatus: String?
    var errorDescription: String? { error }
}
@MainActor final class GenerationStore: ObservableObject {
    @Published var models: [GenerationModel] = []
    @Published var outputs: [GenerationOutput] = []
    @Published var busy = false
    @Published var jobs: [GenerationJob] = []
    @Published private var localJob: GenerationJob?
    @Published var error: String?
    private let session: URLSession
    private let directory: URL
    private let shareDirectory: URL
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoPairingRedirects(), delegateQueue: nil)
    }
    private var nextChecks: [String: Date] = [:]
    @Published private var checkErrors: [String: String] = [:]
    private var activeCredential: DeviceCredential?
    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Generation", isDirectory: true)
        self.shareDirectory = directory?.appendingPathComponent("shares", isDirectory: true) ?? FileManager.default.temporaryDirectory.appendingPathComponent("MakeLORAGenerationShares", isDirectory: true)
        self.session = session ?? Self.makeSession()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
            // Remove only temporary share files left by a previous terminated session.
            for file in try FileManager.default.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: file)
            }
            let job = self.directory.appendingPathComponent("pending.json")
            // Server jobs replace the old single pending marker, which could block all submissions.
            if FileManager.default.fileExists(atPath: job.path) { try FileManager.default.removeItem(at: job) }
        } catch { self.error = "Could not restore generation session: \(error.localizedDescription)" }
    }
    var galleryJobs: [GenerationJob] {
        var visible = jobs.map { job in
            var tile = job
            if let message = checkErrors[job.id] {
                tile.status = "paused"; tile.latestStatus = message
            }
            return tile
        }
        if let localJob { visible = [localJob] + visible.filter { $0.id != localJob.id } }
        return visible
    }
    func watchGallery() async {
        while !Task.isCancelled {
            for job in jobs where job.isProcessing && (nextChecks[job.id] ?? .distantPast) <= Date() {
                await checkStatus(job)
                if Task.isCancelled { return }
            }
            guard await refreshGallery() else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
    func checkStatus(_ job: GenerationJob) async {
        guard let credential = activeCredential else { return }
        do {
            let data = try await request("prediction", credential: credential, id: job.id)
            guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return }
            let reply = try JSONDecoder().decode(Prediction.self, from: data)
            checkErrors[job.id] = nil
            nextChecks[job.id] = Date().addingTimeInterval(Double(max(10, reply.retryAfter ?? 0)))
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].status = reply.status
                jobs[index].latestStatus = reply.latestStatus ?? reply.status.capitalized
            }
            if reply.status == "succeeded" { await refreshGallery() }
        } catch {
            guard !Task.isCancelled, activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return }
            // Status errors stay on their tile, rather than repeatedly interrupting with an alert.
            checkErrors[job.id] = error.localizedDescription
            nextChecks[job.id] = Date().addingTimeInterval(Double(max(10, (error as? GenerationServiceError)?.retryAfter ?? 30)))
        }
    }
    func removeJob(_ job: GenerationJob) async -> Bool {
        if job.id.hasPrefix("submission-") {
            if localJob?.id == job.id { localJob = nil }
            return true
        }
        guard let credential = activeCredential else { return false }
        do {
            _ = try await request("dismiss_generation", credential: credential, body: [:], id: job.id)
            jobs.removeAll { $0.id == job.id }
            if localJob?.id == job.id { localJob = nil }
            nextChecks[job.id] = nil; checkErrors[job.id] = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancelRetries(_ job: GenerationJob) async -> Bool {
        guard let credential = activeCredential else { return false }
        do {
            _ = try await request("cancel_retries", credential: credential, body: [:], id: job.id)
            await refreshGallery()
            return true
        } catch { self.error = error.localizedDescription; return false }
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
    private func verifiedData(_ action: String, output: GenerationOutput) async throws -> Data {
        guard let credential = activeCredential else { throw URLError(.userAuthenticationRequired) }
        let data = try await request(action, credential: credential, id: output.id)
        guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { throw URLError(.cancelled) }
        return data
    }
    func generationDetails(_ output: GenerationOutput) async throws -> GenerationDetails {
        try JSONDecoder().decode(GenerationDetails.self, from: await verifiedData("generation_details", output: output))
    }
    func originalImage(_ output: GenerationOutput) async throws -> Data {
        try await verifiedData("generation_input", output: output)
    }
    func prepareShare(_ output: GenerationOutput) async throws -> URL {
        // A temporary original exists only during the user-requested share sheet.
        let data = try await imageData(output)
        try Task.checkCancellation()
        let url = shareDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    @discardableResult func refreshGallery() async -> Bool {
        guard let credential = activeCredential else { outputs = []; jobs = []; return false }
        do {
            struct Gallery: Decodable { let outputs: [GenerationOutput]; let jobs: [GenerationJob]?; let next: String? }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var collected: [GenerationOutput] = []
            var currentJobs: [GenerationJob] = []
            var before: String?
            repeat {
                let data = try await request("gallery", credential: credential, before: before)
                let page = try decoder.decode(Gallery.self, from: data)
                if before == nil { currentJobs = page.jobs ?? [] }
                collected.append(contentsOf: page.outputs); before = page.next
            } while before != nil
            guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return false }
            outputs = collected; jobs = currentJobs
            let ids = Set(currentJobs.map(\.id))
            nextChecks = nextChecks.filter { ids.contains($0.key) }
            checkErrors = checkErrors.filter { ids.contains($0.key) }
            return true
        } catch {
            if Task.isCancelled { return false }
            outputs = []; jobs = [] // Never retain a gallery after failed access verification.
            self.error = error.localizedDescription
            return false
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
            if var serviceError = try? JSONDecoder().decode(GenerationServiceError.self, from: data) { serviceError.httpStatus = (response as? HTTPURLResponse)?.statusCode; throw serviceError }
            throw NSError(domain: "Generation", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                userInfo: [NSLocalizedDescriptionKey: "The server could not complete this request. Check the connection and retry."])
        }
        return data
    }
    func load(_ credential: DeviceCredential?) async {
        let changed = activeCredential?.deviceID != credential?.deviceID || activeCredential?.server != credential?.server
        activeCredential = credential
        if changed || credential == nil { models = []; outputs = []; jobs = []; localJob = nil; nextChecks = [:]; checkErrors = [:] }
        guard let credential else { return }
        do {
            struct Catalog: Decodable { let models: [GenerationModel] }
            let catalog = try JSONDecoder().decode(Catalog.self, from: await request("models", credential: credential))
            guard activeCredential?.deviceID == credential.deviceID, activeCredential?.server == credential.server else { return }
            models = catalog.models
            await refreshGallery()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func generate(credential: DeviceCredential, model: GenerationModel, image: Data, prompt: String, ratio: String, scale: Double, seed: String, retryOffline: Bool = true, sourceOutputID: String? = nil) async -> GenerationSubmissionOutcome {
        guard !busy else { return .failed }
        activeCredential = credential
        busy = true; error = nil
        localJob = GenerationJob(id: "submission-" + UUID().uuidString, model: model.displayName, prompt: prompt, status: "submitting", latestStatus: "Submitting…")
        defer { busy = false }
        do {
            var body: [String: Any] = ["model": model.id, "image": "data:image/jpeg;base64," + image.base64EncodedString(), "prompt": prompt, "aspect_ratio": ratio, "lora_scale": scale, "retry_offline": retryOffline]
            if let sourceOutputID { body.removeValue(forKey: "image"); body["source_output_id"] = sourceOutputID }
            if !seed.isEmpty {
                guard let value = Int(seed), (0...2147483647).contains(value) else { throw NSError(domain: "Generation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Seed must be a whole number from 0 to 2147483647."]) }
                body["seed"] = value
            }
            let reply = try JSONDecoder().decode(Prediction.self, from: await request("generate", credential: credential, body: body))
            jobs.insert(GenerationJob(id: reply.id, model: model.displayName, prompt: prompt, status: reply.status, latestStatus: reply.latestStatus ?? reply.status.capitalized), at: 0)
            localJob = nil
            await refreshGallery()
            return .submitted
        } catch {
            self.error = error.localizedDescription
            if let service = error as? GenerationServiceError, let id = service.jobID {
                jobs.insert(GenerationJob(id: id, model: model.displayName, prompt: prompt, status: service.jobStatus ?? "unconfirmed", latestStatus: service.error), at: 0)
                localJob = nil
            } else {
                // The response might be lost after acceptance. Dismissing this tile never cancels a paid request.
                localJob?.status = "unconfirmed"
                localJob?.latestStatus = error.localizedDescription
            }
            if sourceOutputID != nil, (error as? GenerationServiceError)?.httpStatus == 404 {
                localJob = nil
                return .sourceUnavailable
            }
            return .failed
        }
        // A failed status check or another active job never prevents a fresh submission.
    }
}
