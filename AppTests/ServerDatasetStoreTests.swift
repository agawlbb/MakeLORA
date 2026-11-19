import XCTest
import Foundation
@testable import MakeLORA

private final class DatasetStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor final class ServerDatasetStoreTests: XCTestCase {
    private func makeStore() -> ServerDatasetStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DatasetStubProtocol.self]
        let store = ServerDatasetStore(session: URLSession(configuration: configuration))
        store.configure(DeviceCredential(server: URL(string: "https://api.fixture.invalid/MakeLORA")!, deviceID: "fixture", token: "fixture-only"))
        return store
    }
    func testConnectedEmptyLibraryCreatesDatasetUsingSeparateManagementOrigin() async throws {
        var created = false
        DatasetStubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value!
            switch action {
            case "datasets": return ["projects": created ? [["id": String(repeating: "a", count: 32), "name": "Fixture", "count": 0]] : []]
            case "dataset_connection":
                return ["configured": true, "connected": true, "workerReady": true, "managementURL": "https://management.fixture.invalid/MakeLORA/filebeans.php"]
            case "dataset_create":
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
                    }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["name"] as? String, "Fixture")
                XCTAssertEqual(body["model"] as? String, "qwen")
                created = true
                return ["id": String(repeating: "a", count: 32), "name": "Fixture", "model": "qwen", "revision": 0, "videos": [], "clips": [], "exportStatus": "none"]
            default: throw URLError(.unsupportedURL)
            }
        }
        defer { DatasetStubProtocol.handler = nil }
        let store = makeStore()
        try await store.refresh()
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(store.connection?.connected, true)
        XCTAssertEqual(store.managementURL?.absoluteString, "https://management.fixture.invalid/MakeLORA/filebeans.php")
        try await store.create("Fixture", model: "qwen")
        XCTAssertEqual(store.project?.model, "qwen")
        XCTAssertEqual(store.projects.count, 1)
        store.configure(DeviceCredential(server: URL(string: "https://other.fixture.invalid/MakeLORA")!, deviceID: "other", token: "other"))
        XCTAssertNil(store.connection)
        XCTAssertEqual(store.managementURL?.host, "other.fixture.invalid")
    }
    func testOriginalReferenceIsReadyWithoutPreparationAndInspectionIsExplicit() async throws {
        let id = String(repeating: "a", count: 32)
        var actions: [String] = []
        let source: [String: Any] = ["id": id, "source": "fixture", "path": "/original.mov", "revision": String(repeating: "b", count: 64), "name": "original.mov", "status": "ready", "sourceURL": "https://api.fixture.invalid/original"]
        DatasetStubProtocol.handler = { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value!
            actions.append(action)
            switch action {
            case "dataset", "dataset_import":
                return ["id": id, "name": "Fixture", "model": "wan", "revision": 1, "videos": [source], "clips": [], "exportStatus": "none"]
            case "dataset_activity": return ["active": true]
            case "dataset_source_access": return ["source": source]
            case "dataset_source_info":
                var inspected = source; inspected["width"] = 1920; inspected["height"] = 1080; inspected["duration"] = 10
                return ["source": inspected]
            default: throw URLError(.unsupportedURL)
            }
        }
        defer { DatasetStubProtocol.handler = nil }
        let store = makeStore()
        try await store.open(id)
        try await store.importSources([FileBeansLocation(source: "fixture", path: "/original.mov")])
        XCTAssertEqual(store.project?.clips.count, 0)
        XCTAssertEqual(store.project?.processing, false)
        XCTAssertNil(store.project?.videos.first?.duration)
        let original = try await store.source(id)
        XCTAssertEqual(original.originalURL?.absoluteString, "https://api.fixture.invalid/original")
        XCTAssertFalse(actions.contains("dataset_source_info"))
        let inspected = try await store.source(id, inspect: true)
        XCTAssertEqual(inspected.duration, 10)
        XCTAssertEqual(store.project?.videos.first?.width, 1920)
        XCTAssertEqual(store.project?.clips.count, 0)
    }
    func testOlderServerConnectionMetadataRemainsCompatible() async throws {
        DatasetStubProtocol.handler = { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value!
            return action == "datasets" ? ["projects": []] : ["configured": true, "connected": true]
        }
        defer { DatasetStubProtocol.handler = nil }
        let store = makeStore()
        try await store.refresh()
        XCTAssertEqual(store.managementURL?.absoluteString, "https://api.fixture.invalid/MakeLORA/filebeans.php")
    }
}
