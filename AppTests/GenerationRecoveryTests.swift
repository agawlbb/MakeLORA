import XCTest
import Foundation
@testable import MakeLORA

private final class GenerationStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func generationAction(_ request: URLRequest) -> String {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value!
}

private func generationBody(_ request: URLRequest) throws -> [String: Any] {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@MainActor final class GenerationRecoveryTests: XCTestCase {
    private let credential = DeviceCredential(server: URL(string: "https://fixture.invalid/MakeLORA")!, deviceID: "fixture-device", token: "fixture-token")
    private let model = GenerationModel(id: "fixture-model", displayName: "Fixture", baseModel: "Qwen/Qwen-Image-Edit-2509", sizeBytes: 1, details: "{}", supported: true)

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationStubProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func submit(_ store: GenerationStore) async {
        await store.generate(credential: credential, model: model, image: Data([1]), prompt: "Edit", ratio: "match_input_image", scale: 1, seed: "")
    }
    func testLegacyPendingMarkerAndRejectionDoNotBlockAnotherSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        let pending = directory.appendingPathComponent("pending.json")
        try Data("legacy marker".utf8).write(to: pending)
        var submissions = 0
        GenerationStubProtocol.handler = { request in
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": []])
            case "generate":
                submissions += 1
                return (502, ["error": "Replicate requires billing credit (HTTP 402).", "jobID": "rejected-job", "jobStatus": "failed", "retryAfter": 30])
            case "dismiss_generation": return (200, ["status": "dismissed"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        await store.load(credential)
        await submit(store)
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.galleryJobs.first?.status, "failed")
        let tile = try XCTUnwrap(store.galleryJobs.first)
        let removed = await store.removeJob(tile)
        XCTAssertTrue(removed)
        XCTAssertTrue(store.galleryJobs.isEmpty)
        await submit(store)
        XCTAssertEqual(submissions, 2)
        XCTAssertFalse(store.busy)
    }

    func testStatusFailureIsInlineAndActiveJobDoesNotBlockNewSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        var submissions = 0
        let active: [String: Any] = ["id": "active-job", "model": "Fixture", "prompt": "Edit", "status": "processing", "latestStatus": "Processing"]
        GenerationStubProtocol.handler = { request in
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": [active]])
            case "prediction": return (429, ["error": "Replicate rate limit reached.", "retryAfter": 60])
            case "generate":
                submissions += 1
                return (201, ["id": "new-job", "status": "starting", "latestStatus": "Starting"])
            case "dismiss_generation": return (200, ["status": "dismissed"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        await store.load(credential)
        let job = try XCTUnwrap(store.galleryJobs.first)
        await store.checkStatus(job)
        XCTAssertEqual(store.galleryJobs.first?.status, "paused")
        XCTAssertNil(store.error, "Background polling must not repeatedly open alerts")
        await submit(store)
        XCTAssertEqual(submissions, 1)
        XCTAssertFalse(store.busy, "Submission ends without waiting for the active run")
        let removed = await store.removeJob(job)
        XCTAssertTrue(removed, "Removing a paused tile must not require provider availability")
        XCTAssertFalse(store.galleryJobs.contains { $0.id == job.id })
    }

    func testLostSubmissionResponseCanBeDismissedLocallyAndRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        var submissions = 0
        GenerationStubProtocol.handler = { request in
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": []])
            case "generate": submissions += 1; throw URLError(.timedOut)
            default: XCTFail("Local dismissal must not need another server request"); throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        await store.load(credential)
        await submit(store)
        let tile = try XCTUnwrap(store.galleryJobs.first)
        XCTAssertEqual(tile.status, "unconfirmed")
        let removed = await store.removeJob(tile)
        XCTAssertTrue(removed)
        await submit(store)
        XCTAssertEqual(submissions, 2)
        XCTAssertFalse(store.busy)
    }
    func testQueuedRetryShowsScheduleAndCanBeStoppedWithoutBlockingSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        var rows: [[String: Any]] = []
        var optedIn = false
        GenerationStubProtocol.handler = { request in
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": rows])
            case "generate":
                let value = try generationBody(request)
                optedIn = value["retry_offline"] as? Bool == true
                rows = [["id": "queued-job", "model": "Fixture", "prompt": "Edit", "status": "retry_scheduled",
                         "latestStatus": "Retry scheduled", "retryEnabled": true, "canCancelRetries": true,
                         "retryCount": 0, "nextRetryAt": "2026-11-12T12:30:00Z", "retryUntil": "2026-11-13T00:00:00Z"]]
                return (200, ["id": "queued-job", "status": "retry_scheduled", "latestStatus": "Retry scheduled"])
            case "cancel_retries":
                rows[0]["status"] = "retry_canceled"; rows[0]["latestStatus"] = "Automatic retries stopped."
                rows[0]["canCancelRetries"] = false; rows[0].removeValue(forKey: "nextRetryAt")
                return (200, ["status": "retry_canceled"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        await store.load(credential)
        await submit(store)
        XCTAssertTrue(optedIn)
        XCTAssertFalse(store.busy)
        let job = try XCTUnwrap(store.galleryJobs.first)
        XCTAssertEqual(job.canCancelRetries, true)
        XCTAssertNotNil(job.nextRetryAt)
        XCTAssertFalse(job.isProcessing)
        XCTAssertNil(store.error, "A queued retry must not show the submission as an unrecoverable error")
        let stopped = await store.cancelRetries(job)
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.galleryJobs.first?.status, "retry_canceled")
        XCTAssertEqual(store.galleryJobs.first?.canCancelRetries, false)
    }

    func testReplayLoadsSettingsAndReusesServerOriginalWithoutUploadingImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        var submitted: [String: Any] = [:]
        GenerationStubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": []])
            case "generation_details":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value, "original-output")
                return (200, ["legacy": false, "hasInput": true, "settings": ["modelID": "fixture-model", "modelName": "Fixture", "prompt": "Original prompt", "aspectRatio": "4:3", "loraScale": 0.75, "retryOffline": false]])
            case "generate":
                submitted = try generationBody(request)
                return (200, ["id": "new-job", "status": "starting"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        await store.load(credential)
        let output = GenerationOutput(id: "original-output", model: "Fixture", prompt: "Original prompt", date: Date())
        let details = try await store.generationDetails(output)
        XCTAssertEqual(details.settings.aspectRatio, "4:3")
        XCTAssertNil(details.settings.seed)
        await store.generate(credential: credential, model: model, image: Data([1]), prompt: "Edited prompt", ratio: "4:3", scale: 0.75, seed: "", retryOffline: false, sourceOutputID: output.id)
        XCTAssertEqual(submitted["source_output_id"] as? String, output.id)
        XCTAssertNil(submitted["image"])
        XCTAssertNil(submitted["seed"])
        XCTAssertEqual(submitted["prompt"] as? String, "Edited prompt")
        XCTAssertEqual(submitted["retry_offline"] as? Bool, false)
        XCTAssertNil(store.error)
    }

    func testDeletedReplaySourceCanBeReplacedWithoutBlockingAnotherSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); GenerationStubProtocol.handler = nil }
        var submissions = 0
        GenerationStubProtocol.handler = { request in
            switch generationAction(request) {
            case "models": return (200, ["models": []])
            case "gallery": return (200, ["outputs": [], "jobs": []])
            case "generate":
                submissions += 1
                let body = try generationBody(request)
                if body["source_output_id"] != nil { return (404, ["error": "Original photo unavailable. Choose an input photo to run again."]) }
                XCTAssertNotNil(body["image"])
                return (200, ["id": "replacement-job", "status": "starting"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = GenerationStore(directory: directory, session: session())
        await store.load(credential)
        let result = await store.generate(credential: credential, model: model, image: Data([1]), prompt: "Edit", ratio: "match_input_image", scale: 1, seed: "", sourceOutputID: "deleted-output")
        if case .sourceUnavailable = result {} else { XCTFail("Deleted replay source must request a replacement photo") }
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.galleryJobs.isEmpty)
        await submit(store)
        XCTAssertEqual(submissions, 2)
        XCTAssertNil(store.error)
    }

}
