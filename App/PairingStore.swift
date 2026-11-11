import Foundation
import Combine
import Security
import MakeLORACore

struct DeviceCredential: Codable {
    let server: URL
    let deviceID: String
    let token: String
}
struct PairingReply: Decodable {
    let deviceID: String
    let status: String
    let confirmation: String
    let token: String?
}
private struct ServiceError: Decodable { let error: String }
private final class NoPairingRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class PairingStore: ObservableObject {
    @Published var credential: DeviceCredential?
    @Published var status = "Not connected"
    @Published var confirmation: String?
    @Published var error: String?
    @Published var busy = false
    private var pending: DeviceCredential?
    private let service = "dev.makelora.app.pairing"
    private let session = URLSession(configuration: .ephemeral, delegate: NoPairingRedirects(), delegateQueue: nil)

    init() {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"device", kSecReturnData as String:true]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            credential = try? JSONDecoder().decode(DeviceCredential.self, from: data)
            if credential != nil { status = "Saved connection · Check status to verify" }
        }
    }
    private func save(_ value: DeviceCredential) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"device"]
        let data = try JSONEncoder().encode(value)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if update == errSecItemNotFound {
            var item=query; item[kSecValueData as String]=data; item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw NSError(domain:"Keychain",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not securely save the connection."]) }
        } else if update != errSecSuccess { throw NSError(domain:"Keychain",code:Int(update),userInfo:[NSLocalizedDescriptionKey:"Could not securely save the connection."]) }
        credential=value
    }
    private func request(_ action: String, server: URL, token: String? = nil, body: [String:String]? = nil) async throws -> Data {
        var parts=URLComponents(url:server.appendingPathComponent("api.php"),resolvingAgainstBaseURL:false)!
        parts.queryItems=[URLQueryItem(name:"action",value:action)]
        var req=URLRequest(url:parts.url!); req.timeoutInterval=20
        req.httpMethod=body == nil ? "GET":"POST"
        if let token { req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }
        if let body { req.httpBody=try JSONEncoder().encode(body); req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await session.data(for:req)
        guard let http=response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain:"Pairing",code:(response as? HTTPURLResponse)?.statusCode ?? 0,userInfo:[NSLocalizedDescriptionKey:(try? JSONDecoder().decode(ServiceError.self,from:data).error) ?? "The pairing server could not complete this request."])
        }
        return data
    }
    func pair(_ invitation: PairingInvitation, name: String) async {
        busy=true; error=nil
        defer { busy=false }
        do {
            if let old=pending { _ = try? await request("disconnect",server:old.server,token:old.token,body:[:]) }
            let data=try await request("redeem",server:invitation.server,body:["invitation":invitation.invitation,"name":name])
            let reply=try JSONDecoder().decode(PairingReply.self,from:data)
            guard let token=reply.token else { throw PairingError.invalidInvitation }
            pending=DeviceCredential(server:invitation.server,deviceID:reply.deviceID,token:token)
            confirmation=reply.confirmation; status="Waiting for approval on the website"
        } catch { self.error=error.localizedDescription }
    }
    func check() async {
        guard let value=pending ?? credential, !busy else { return }
        busy=true; error=nil; defer { busy=false }
        do {
            let data=try await request("status",server:value.server,token:value.token)
            let reply=try JSONDecoder().decode(PairingReply.self,from:data)
            if reply.status=="active" { try save(value); pending=nil; confirmation=nil; status="Connected" }
            else { confirmation=reply.confirmation; status="Waiting for approval on the website" }
        } catch { status="Connection could not be verified"; self.error=error.localizedDescription }
    }
    func disconnect() async {
        guard !busy else { return }; busy=true; error=nil; defer { busy=false }
        if let value=pending ?? credential {
            do { _ = try await request("disconnect",server:value.server,token:value.token,body:[:]) }
            catch { self.error="Local connection removed. Server revocation could not be confirmed; revoke it on the website if necessary." }
        }
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"device"]
        let result=SecItemDelete(query as CFDictionary)
        guard result==errSecSuccess || result==errSecItemNotFound else { error="Could not remove the saved credential from Keychain. Try again."; return }
        credential=nil; pending=nil; confirmation=nil; status="Not connected"
    }
    var hasConnection: Bool { pending != nil || credential != nil }
}
