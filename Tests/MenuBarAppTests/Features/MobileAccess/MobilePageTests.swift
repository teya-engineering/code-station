import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct MobilePageTests {
    @Test func servesBundledAssetsWithTheRightTypesAndPolicy() async throws {
        let server = LANWebSocketServer(page: MobilePage.data, resource: { MobilePage.resource($0) },
                                        onOpen: { _, _ in }, onMessage: { _, _ in }, onClose: { _ in })
        let port = try await server.start()
        defer { server.stop() }
        let root = "http://127.0.0.1:\(port)"
        let (page, response) = try await URLSession.shared.data(from: URL(string: root + "/mobile/test")!)
        let html = String(decoding: page, as: UTF8.self)
        #expect(html.contains("/assets/mobile-session.css"))
        #expect(html.contains("/assets/mobile-session.js"))
        let policy = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy"))
        #expect(policy.contains("script-src 'self'"))
        #expect(policy.contains("style-src 'self'"))
        for (ext, type) in [("js", "text/javascript"), ("css", "text/css")] {
            let path = "/assets/mobile-session.\(ext)"
            let expected = try #require(MobilePage.resource(path))
            let (data, response) = try await URLSession.shared.data(from: URL(string: root + path)!)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == type + "; charset=utf-8")
            #expect(data == expected.data)
        }
        #expect(MobilePage.resource("/assets/../site-defaults.json") == nil)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: root + "/assets/missing.js")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }
}
