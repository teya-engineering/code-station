import Foundation
import JavaScriptCore
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct MobileDesignTests {
    @Test func servesOnlyManifestScreensAndSupportedAssets() throws {
        let scratch = ScratchDirectory(prefix: "mobile-design")
        try "<button>Preview</button>".write(to: scratch.path("index.html"), atomically: true, encoding: .utf8)
        try "<p>Unpublished</p>".write(to: scratch.path("private.html"), atomically: true, encoding: .utf8)
        try "body { color: green; }".write(to: scratch.path("style.css"), atomically: true, encoding: .utf8)
        try "handoff".write(to: scratch.path("handoff.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: scratch.path("reference"), withIntermediateDirectories: true)
        try "reference".write(to: scratch.path("reference/style.css"), atomically: true, encoding: .utf8)

        #expect(RemoteDesignArtifacts.resource("index.html", in: scratch.url)?.contentType == "text/html; charset=utf-8")
        #expect(RemoteDesignArtifacts.resource("style.css", in: scratch.url)?.contentType == "text/css; charset=utf-8")
        #expect(RemoteDesignArtifacts.resource("private.html", in: scratch.url) == nil)
        #expect(RemoteDesignArtifacts.resource("handoff.md", in: scratch.url) == nil)
        #expect(RemoteDesignArtifacts.resource("reference/style.css", in: scratch.url) == nil)
        #expect(RemoteDesignArtifacts.resource("../index.html", in: scratch.url) == nil)
        #expect(RemoteDesignArtifacts.resource("./index.html", in: scratch.url) == nil)

        let manifest = DesignManifest(screens: [DesignScreen(id: "other", title: "Other", path: "private.html")])
        try JSONEncoder().encode(manifest).write(to: scratch.path("design.json"))
        #expect(RemoteDesignArtifacts.resource("private.html", in: scratch.url) != nil)
        #expect(RemoteDesignArtifacts.resource("index.html", in: scratch.url) == nil)
    }

    @Test func refusesSymlinksOutsideTheDesign() throws {
        let scratch = ScratchDirectory(prefix: "mobile-design-link")
        let outside = ScratchDirectory(prefix: "mobile-design-outside")
        try "private".write(to: outside.path("private.css"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scratch.path("style.css"),
                                                   withDestinationURL: outside.path("private.css"))
        #expect(RemoteDesignArtifacts.resource("style.css", in: scratch.url) == nil)
    }

    @Test func searchAndStatusFiltersComposeWithoutChangingDirectoryData() throws {
        let function = try mobileFunction("filteredProjects", before: "renderDirectory")
        let context = try #require(JSContext())
        let result = try #require(context.evaluateScript("""
        \(function)
        const projects = [
          { name: 'Code Station', sessions: [
            { title: 'Pairing', agent: 'Codex', branch: 'mobile', state: 'NEEDS YOU' },
            { title: 'Search', agent: 'Claude', branch: 'main', state: 'RUNNING' }
          ] },
          { name: 'Settings', sessions: [
            { title: 'Validate', agent: 'Codex', branch: 'config', state: 'RUNNING' }
          ] }
        ];
        JSON.stringify([
          filteredProjects(projects, 'wait', ' MOBILE ')[0].sessions[0].title,
          filteredProjects(projects, 'run', 'codex')[0].name,
          filteredProjects(projects, 'wait', 'settings').length,
          filteredProjects(projects, 'all', 'station')[0].sessions.length,
          projects[0].sessions.length
        ]);
        """))
        #expect(result.toString() == #"["Pairing","Settings",0,2,2]"#)
    }

    @Test func remoteCommandsWaitForAuthenticationAndNameTheirConversation() throws {
        let function = try mobileFunction("send", before: "remoteButton")
        let context = try #require(JSContext())
        let result = try #require(context.evaluateScript("""
        let authenticated = false;
        const WebSocket = { OPEN: 1 };
        const sent = [];
        const socket = { readyState: 1, send: text => sent.push(JSON.parse(text)) };
        const showError = () => {};
        const activeSessionID = 'main-session';
        const conversation = 'design';
        \(function)
        const blocked = send({ type: 'answerPermission', answer: 'allowOnce' });
        authenticated = true;
        const accepted = send({ type: 'sendPrompt', prompt: '<literal text>' });
        JSON.stringify([blocked, accepted, sent]);
        """))
        #expect(result.toString() == #"[false,true,[{"sessionID":"main-session","conversation":"design","type":"sendPrompt","prompt":"<literal text>"}]]"#)
    }

    @Test func designResponsesAreSandboxedAndMissingCapabilitiesAreNotServed() async throws {
        let server = LANWebSocketServer(page: Data(), resource: { path in
            guard path == "/design/capability/index.html" else { return nil }
            return LANResource(data: Data("<button>Preview</button>".utf8), contentType: "text/html")
        }, onOpen: { _, _ in }, onMessage: { _, _ in }, onClose: { _ in })
        let port = try await server.start()
        defer { server.stop() }
        let root = "http://127.0.0.1:\(port)"
        let (_, response) = try await URLSession.shared.data(from: URL(string: root + "/design/capability/index.html")!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let policy = try #require(http.value(forHTTPHeaderField: "Content-Security-Policy"))
        #expect(policy.contains("sandbox allow-scripts;"))
        #expect(!policy.contains("allow-same-origin"))
        #expect(policy.contains("connect-src 'none'"))
        #expect(http.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
        let (_, missing) = try await URLSession.shared.data(from: URL(string: root + "/design/wrong/index.html")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    private func mobileFunction(_ name: String, before next: String) throws -> String {
        let url = try #require(AppResources.bundle.url(forResource: "mobile-session", withExtension: "js"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(html.range(of: "const \(name) ="))
        let end = try #require(html.range(of: "const \(next) =", range: start.upperBound..<html.endIndex))
        return String(html[start.lowerBound..<end.lowerBound])
    }
}

@MainActor
struct MobileDesignPairingTests {
    private let testPreferences = TestPreferences()
    @Test(.enabled(if: LANAddress.currentIPv4() != nil, "Requires a local network interface"))
    func pairedScopeControlsDesignFilesAndCompanionConversation() async throws {
        let scratch = ScratchDirectory(prefix: "mobile-design-pairing")
        let store = ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json"))
        let project = try TestStore.project(in: store)
        let main = try store.insertSession(in: project.id, seed: .init(agent: .codex)).get()
        let other = try store.insertSession(in: project.id, seed: .init(agent: .codex)).get()
        let companion = try store.startDesign(for: main.id).get()
        store.append(ChatMessage(role: .assistant, text: "Main conversation"), to: main.id)
        store.append(ChatMessage(role: .assistant, text: "Design conversation"), to: companion.id)
        let directory = store.designDirectory(for: companion)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "<button>Preview</button>".write(to: directory.appendingPathComponent("index.html"),
                                          atomically: true, encoding: .utf8)
        let runner = SessionRunner(preferences: testPreferences.store, paths: [:])
        let controller = MobileAccessController(store: store, runner: runner, gitStats: GitStatsCache())
        controller.setEnabled(true)
        defer { controller.stop() }
        let share = try await controller.startSharing()
        let components = try #require(URLComponents(url: share.url, resolvingAgainstBaseURL: false))
        let port = try #require(components.port)
        let secret = try #require(components.fragment?.split(separator: "=").last.map(String.init))
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/socket/\(share.id)")!)
        socket.resume()
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string(#"{"type":"authenticate","version":1,"secret":"\#(secret)"}"#))
        let list = try await receive("directory", from: socket)
        let projects = list["projects"] as? [[String: Any]] ?? []
        let listed = Set(projects.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .compactMap { $0["id"] as? String })
        #expect(listed.isSuperset(of: [main.id.uuidString, other.id.uuidString]))
        try await socket.send(.string(#"{"type":"openSession","sessionID":"\#(main.id)"}"#))
        let initial = try await receive("snapshot", from: socket)
        #expect(initial["conversation"] as? String == "main")
        let design = try await receive("design", from: socket)
        let screens = try #require(design["screens"] as? [[String: String]])
        let path = try #require(screens.first?["url"])
        let artifactURL = try #require(URL(string: "http://127.0.0.1:\(port)" + path))
        let (html, response) = try await URLSession.shared.data(from: artifactURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: html, encoding: .utf8) == "<button>Preview</button>")

        try await socket.send(.string(#"{"type":"openSession","sessionID":"\#(UUID())"}"#))
        let refused = try await receive("error", from: socket)
        #expect(refused["code"] as? String == "commandFailed")
        try await socket.send(.string(#"{"type":"openConversation","conversation":"design"}"#))
        let conversation = try await receive("snapshot", from: socket)
        #expect(conversation["conversation"] as? String == "design")
        #expect(conversation["sessionID"] as? String == main.id.uuidString)
        #expect((conversation["messages"] as? [[String: Any]])?.last?["text"] as? String == "Design conversation")

        try await socket.send(.string(#"{"type":"sendPrompt","sessionID":"\#(main.id)","conversation":"main","prompt":"Wrong destination"}"#))
        let stale = try await receive("error", from: socket)
        #expect(stale["message"] as? String == "The conversation changed. Try again.")
        #expect(!store.transcript(of: main.id).contains { $0.text == "Wrong destination" })
        #expect(!store.transcript(of: companion.id).contains { $0.text == "Wrong destination" })

        try "<button>Updated preview</button>".write(to: directory.appendingPathComponent("index.html"),
                                                  atomically: true, encoding: .utf8)
        let updated = try await receive("design", from: socket)
        #expect(updated["revision"] as? String != design["revision"] as? String)
        controller.revoke()
        let ended = try await receive("error", from: socket)
        #expect(ended["code"] as? String == "pairingEnded")
        let revoked = try? await URLSession.shared.data(from: artifactURL)
        #expect((revoked?.1 as? HTTPURLResponse)?.statusCode != 200)
    }

    private func receive(_ type: String, from socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        for _ in 0..<10 {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            if payload["type"] as? String == type { return payload }
        }
        throw LANServerFailure(message: "Did not receive \(type)")
    }
}
