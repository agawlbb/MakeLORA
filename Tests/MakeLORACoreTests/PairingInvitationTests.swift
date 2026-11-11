import XCTest
@testable import MakeLORACore

final class PairingInvitationTests: XCTestCase {
    private func invitation(server: String = "https://test.example/makelora", version: Int = 1, token: String = String(repeating: "a", count: 64)) -> String {
        "{\"version\":\(version),\"server\":\"\(server)\",\"invitation\":\"\(token)\"}"
    }
    func testValidInvitation() throws {
        let value = try PairingInvitation.parse(invitation())
        XCTAssertEqual(value.server.absoluteString, "https://test.example/makelora")
        XCTAssertEqual(value.invitation.count, 64)
    }
    func testRejectsUntrustedShapes() {
        for server in ["http://test.example", "file:///tmp/server", "https://user:password@test.example", "https://test.example?redirect=elsewhere", "https://test.example/#fragment"] {
            XCTAssertThrowsError(try PairingInvitation.parse(invitation(server: server)))
        }
        XCTAssertThrowsError(try PairingInvitation.parse(invitation(version: 2)))
        XCTAssertThrowsError(try PairingInvitation.parse(invitation(token: "short")))
        XCTAssertThrowsError(try PairingInvitation.parse(invitation(token: String(repeating: "z", count: 64))))
        XCTAssertThrowsError(try PairingInvitation.parse(String(repeating: "a", count: 4097)))
        XCTAssertThrowsError(try PairingInvitation.parse("not JSON"))
    }
}
