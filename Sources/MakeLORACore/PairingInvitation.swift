import Foundation

public struct PairingInvitation: Codable, Equatable {
    public let version: Int
    public let server: URL
    public let invitation: String

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 4096 else { throw PairingError.invalidInvitation }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.version == 1, value.server.scheme == "https",
              let host = value.server.host, !host.isEmpty,
              value.server.user == nil, value.server.password == nil,
              value.server.query == nil, value.server.fragment == nil,
              value.invitation.count == 64,
              value.invitation.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw PairingError.invalidInvitation }
        return value
    }
}

public enum PairingError: LocalizedError {
    case invalidInvitation
    public var errorDescription: String? { "Use a valid MakeLORA pairing invitation with an HTTPS server address." }
}
