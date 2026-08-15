import Foundation
import Testing
@testable import MenuBarApp

struct MobileAccessTests {
    @Test func mobileAccessStaysOffUntilItIsEnabled() throws {
        let suite = "mobile-access-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!Preferences.mobileAccessEnabled(in: defaults))
        defaults.set(true, forKey: "mobileAccessEnabled")
        #expect(Preferences.mobileAccessEnabled(in: defaults))
    }

    @Test func choosesTheActivePrivateWiFiAddress() {
        let candidates = [
            LANInterfaceAddress(name: "lo0", address: "127.0.0.1",
                                isUp: true, isRunning: true),
            LANInterfaceAddress(name: "en1", address: "192.168.1.80",
                                isUp: true, isRunning: true),
            LANInterfaceAddress(name: "en0", address: "192.168.1.42",
                                isUp: true, isRunning: true),
            LANInterfaceAddress(name: "en0", address: "10.0.0.9",
                                isUp: false, isRunning: false),
        ]

        #expect(LANAddress.preferredIPv4(from: candidates) == "192.168.1.42")
    }

    @Test func ignoresLinkLocalAndMalformedAddresses() {
        let candidates = [
            LANInterfaceAddress(name: "en0", address: "169.254.3.4",
                                isUp: true, isRunning: true),
            LANInterfaceAddress(name: "en1", address: "not-an-address",
                                isUp: true, isRunning: true),
        ]

        #expect(LANAddress.preferredIPv4(from: candidates) == nil)
    }

    // This is the example from RFC 6455. A mismatch here means browsers will refuse the
    // upgrade before the mobile protocol gets a chance to authenticate.
    @Test func acceptsAWebSocketUpgrade() {
        #expect(WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func readsAMaskedBrowserFrame() throws {
        var decoder = WebSocketFrameDecoder()
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        let text = Data("hello".utf8)
        let masked = text.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }
        let frame = Data([0x81, 0x80 | UInt8(text.count)] + mask + masked)

        #expect(try decoder.append(frame) == [.text("hello")])
    }

    @Test func waitsForAWholeFrame() throws {
        var decoder = WebSocketFrameDecoder()
        let first = Data([0x81, 0x82, 0x01, 0x02])
        let second = Data([0x03, 0x04, 0x68 ^ 0x01, 0x69 ^ 0x02])

        #expect(try decoder.append(first).isEmpty)
        #expect(try decoder.append(second) == [.text("hi")])
    }

    @Test func decodesTheVersionedMobileCommands() throws {
        let auth = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data(#"{"type":"authenticate","version":1,"secret":"pair-me"}"#.utf8))
        let prompt = try JSONDecoder().decode(
            RemoteCommand.self, from: Data(#"{"type":"sendPrompt","prompt":"Run the tests"}"#.utf8))

        #expect(auth == RemoteCommand(type: "authenticate", version: 1, secret: "pair-me"))
        #expect(prompt == RemoteCommand(type: "sendPrompt", prompt: "Run the tests"))
    }

    @Test func createsAReadablePairingCode() {
        let url = URL(string: "http://192.168.1.42:49152/mobile/123#secret=test")!
        let image = MobilePairingQRCode.image(for: url)

        #expect(image != nil)
        #expect(image?.size.width ?? 0 > 100)
    }

    @Test func servesTheMobilePageOnTheLocalListener() async throws {
        let expected = Data("<html>mobile</html>".utf8)
        let server = LANWebSocketServer(page: expected,
                                        onOpen: { _, _ in },
                                        onMessage: { _, _ in },
                                        onClose: { _ in })
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(port)/mobile/\(UUID().uuidString)")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)

        #expect(data == expected)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control")
                == "no-store")
    }
}
