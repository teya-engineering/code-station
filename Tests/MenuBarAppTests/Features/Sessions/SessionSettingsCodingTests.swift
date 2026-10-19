import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct SessionSettingsCodingTests {
    @Test func typedChoicesKeepTheSavedStringFormat() throws {
        let json = Data(#"{"permissionMode":"auto","codexSandboxMode":"approve-for-me","copilotAccessMode":"full-access","designAmbition":"all-out"}"#.utf8)
        let settings = try JSONDecoder().decode(SessionSettings.self, from: json)
        #expect(settings.permissionMode == .auto)
        #expect(settings.codexSandboxMode == .approveForMe)
        #expect(settings.copilotAccessMode == .fullAccess)
        #expect(settings.designAmbition == .allOut)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: String]
        #expect(encoded == ["permissionMode": "auto", "codexSandboxMode": "approve-for-me",
                            "copilotAccessMode": "full-access", "designAmbition": "all-out"])
    }

    @Test func unknownChoicesDoNotPreventReadingAConversation() throws {
        let json = Data(#"{"permissionMode":"retired","codexSandboxMode":"retired","copilotAccessMode":"retired","designAmbition":"retired"}"#.utf8)
        let settings = try JSONDecoder().decode(SessionSettings.self, from: json)
        #expect(settings.permissionMode == .fallback)
        #expect(settings.codexSandboxMode == .workspaceWrite)
        #expect(settings.copilotAccessMode == .workspace)
        #expect(settings.designAmbition == nil)
        #expect(try JSONDecoder().decode(SessionSettings.self, from: Data("{}".utf8)) == SessionSettings())
    }
}
