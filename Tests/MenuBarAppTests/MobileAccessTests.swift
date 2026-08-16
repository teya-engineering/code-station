import Foundation
import JavaScriptCore
import Testing
@testable import MenuBarApp

struct MobileAccessTests {
    @Test func mobilePageSplitsFencedMarkdownIntoACodeBlock() throws {
        let segments = try mobileFencedSegments("""
        Before

        ```md
        # Heading

        - item
        ```

        After
        """)

        #expect(segments == [
            ["kind": "prose", "text": "Before"],
            ["kind": "code", "text": "# Heading\n\n- item", "language": "md"],
            ["kind": "prose", "text": "After"],
        ])
    }

    @Test func mobilePageTreatsAnUnclosedFenceAsStreamingCode() throws {
        let segments = try mobileFencedSegments("Working\n\n```swift\nlet answer = 42")

        #expect(segments == [
            ["kind": "prose", "text": "Working"],
            ["kind": "code", "text": "let answer = 42", "language": "swift"],
        ])
    }

    @Test func mobilePageRendersQueuedMessageDetails() throws {
        let url = try #require(AppResources.bundle.url(
            forResource: "mobile-session", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(html.range(of: "const renderQueue"))
        let end = try #require(html.range(
            of: "\n\n      const renderHeader", range: start.upperBound..<html.endIndex))
        let function = html[start.lowerBound..<end.lowerBound]
        let context = try #require(JSContext())
        let value = try #require(context.evaluateScript("""
        let queuedPrompts = [{ text: 'Run the tests', attachments: ['test-plan.md'] }];
        const header = { isBusy: true };
        const queuedPanel = { hidden: true };
        const queuedHead = { textContent: '' };
        const queuedList = {
          children: [],
          replaceChildren(...children) { this.children = children; }
        };
        const element = (tag, className, text) => ({
          tag, className, textContent: text, children: [],
          append(...children) { this.children.push(...children); }
        });
        \(function)
        renderQueue();
        JSON.stringify([
          String(queuedPanel.hidden),
          queuedHead.textContent,
          queuedList.children[0].children[0].textContent,
          queuedList.children[0].children[1].textContent
        ]);
        """))
        let data = try #require(value.toString().data(using: .utf8))

        #expect(try JSONDecoder().decode([String].self, from: data) == [
            "false",
            "QUEUED · 1 · RUNS WHEN THIS TURN ENDS",
            "Run the tests",
            "test-plan.md",
        ])
    }

    private func mobileFencedSegments(_ text: String) throws -> [[String: String]] {
        let url = try #require(AppResources.bundle.url(
            forResource: "mobile-session", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(html.range(of: "const fencedSegments"))
        let end = try #require(html.range(
            of: "\n\n      const renderProse", range: start.upperBound..<html.endIndex))
        let function = html[start.lowerBound..<end.lowerBound]
        let argument = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let context = try #require(JSContext())
        let value = try #require(context.evaluateScript("""
        \(function)
        JSON.stringify(fencedSegments(\(argument)));
        """))
        let data = try #require(value.toString().data(using: .utf8))
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }

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

    // The whole of what a QR code is allowed to reach, since every command from the phone
    // is checked against it.
    @Test func aSessionCodeReachesOnlyItsOwnSession() {
        let projectID = UUID()
        let mine = ChatSession(projectID: projectID, agent: .claudeCode)
        let other = ChatSession(projectID: projectID, agent: .claudeCode)
        let scope = MobileScope.session(mine.id)

        #expect(scope.allows(mine))
        #expect(!scope.allows(other))
        #expect(!scope.allows(project: projectID))
        #expect(!scope.canBrowse)
        #expect(!scope.canCreate)
    }

    @Test func aProjectCodeReachesEverySessionInThatProject() {
        let projectID = UUID()
        let elsewhere = UUID()
        let scope = MobileScope.project(projectID)

        #expect(scope.allows(ChatSession(projectID: projectID, agent: .claudeCode)))
        #expect(!scope.allows(ChatSession(projectID: elsewhere, agent: .claudeCode)))
        #expect(scope.allows(project: projectID))
        #expect(!scope.allows(project: elsewhere))
        #expect(scope.canBrowse)
        #expect(scope.canCreate)
    }

    @Test func theWholeAppCodeReachesEveryProject() {
        let scope = MobileScope.everything

        #expect(scope.allows(ChatSession(projectID: UUID(), agent: .claudeCode)))
        #expect(scope.allows(project: UUID()))
        #expect(scope.canBrowse)
        #expect(scope.canCreate)
    }

    @Test func decodesTheCommandsThatMoveAroundTheApp() throws {
        let sessionID = UUID()
        let projectID = UUID()
        let open = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data(#"{"type":"openSession","sessionID":"\#(sessionID.uuidString)"}"#.utf8))
        let create = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("""
            {"type":"createSession","projectID":"\(projectID.uuidString)",\
            "worktree":true,"prompt":"Fix the flaky test"}
            """.utf8))

        #expect(open.type == "openSession")
        #expect(open.sessionID == sessionID.uuidString)
        #expect(create.projectID == projectID.uuidString)
        #expect(create.worktree == true)
        #expect(create.prompt == "Fix the flaky test")
    }

    @Test func sendsOnlyTheCharactersAnAnswerGained() {
        let id = UUID()
        let date = Date()
        let started = RemoteMessage(ChatMessage(id: id, role: .assistant,
                                                text: "Reading the", date: date))
        let grown = RemoteMessage(ChatMessage(id: id, role: .assistant,
                                              text: "Reading the tests now", date: date))

        let change = RemoteTranscriptDiff.change(
            from: RemoteTranscriptDiff.digest(of: started),
            to: RemoteTranscriptDiff.digest(of: grown),
            message: grown)

        #expect(change.kind == "patch")
        #expect(change.textAppend == " tests now")
        #expect(change.text == nil)
        #expect(change.tools == nil)
    }

    @Test func sendsAssistantContentInTheOrderItHappened() throws {
        var firstThought = ThinkingSegment(text: "Plan the change")
        firstThought.textOffset = 0
        firstThought.toolOffset = 0
        var secondThought = ThinkingSegment(text: "Check the result")
        secondThought.textOffset = 8
        secondThought.toolOffset = 0
        let call = ToolUse(id: "call-1", name: "Read", input: "Package.swift", result: "ok",
                           textOffset: 8)
        var message = ChatMessage(role: .assistant, text: "Looking.\n\nDone.", tools: [call])
        message.thinking = [firstThought, secondThought]

        let remote = RemoteMessage(message)

        #expect(remote.blocks.map(\.kind) == ["thinking", "prose", "thinking", "tools", "prose"])
        #expect(remote.blocks.compactMap(\.text)
            == ["Plan the change", "Looking.", "Check the result", "\n\nDone."])
        #expect(remote.blocks.flatMap { $0.tools ?? [] }.map(\.id) == ["call-1"])
    }

    @Test func sendsOnlyTheToolThatMoved() {
        let id = UUID()
        let date = Date()
        let running = ToolUse(id: "call-1", name: "Bash", input: "swift test", result: nil)
        let quiet = ToolUse(id: "call-2", name: "Read", input: "Package.swift", result: "ok")
        let before = RemoteMessage(ChatMessage(id: id, role: .assistant, text: "Working",
                                               tools: [running, quiet], date: date))
        var finished = running
        finished.result = "3 tests passed"
        let after = RemoteMessage(ChatMessage(id: id, role: .assistant, text: "Working",
                                              tools: [finished, quiet], date: date))

        let change = RemoteTranscriptDiff.change(
            from: RemoteTranscriptDiff.digest(of: before),
            to: RemoteTranscriptDiff.digest(of: after),
            message: after)

        #expect(change.kind == "patch")
        #expect(change.textAppend == nil)
        #expect(change.tools?.map(\.id) == ["call-1"])
        #expect(change.tools?.first?.result == "3 tests passed")
    }

    // Rewind and clear-context rewrite what the phone already drew, and a patch has no way
    // to take text back.
    @Test func fallsBackToTheWholeMessageWhenTextIsRewritten() {
        let id = UUID()
        let date = Date()
        let before = RemoteMessage(ChatMessage(id: id, role: .assistant,
                                               text: "Reading the tests", date: date))
        let after = RemoteMessage(ChatMessage(id: id, role: .assistant,
                                              text: "Writing the docs", date: date))

        let change = RemoteTranscriptDiff.change(
            from: RemoteTranscriptDiff.digest(of: before),
            to: RemoteTranscriptDiff.digest(of: after),
            message: after)

        #expect(change.kind == "full")
        #expect(change.text == "Writing the docs")
        #expect(change.textAppend == nil)
    }

    @Test func leavesAnUpdateEmptyWhenNothingMoved() {
        let message = RemoteMessage(ChatMessage(role: .assistant, text: "Done"))
        let digest = RemoteTranscriptDiff.digest(of: message)

        #expect(digest == RemoteTranscriptDiff.digest(of: message))
        #expect(RemoteUpdate().isEmpty)
        #expect(!RemoteUpdate(order: ["a"]).isEmpty)
        #expect(!RemoteUpdate(permissionCleared: true).isEmpty)
    }

    @Test func sendsQueuedMessageTextAndAttachmentNames() {
        let prompt = SessionRunner.QueuedPrompt(
            text: "Run the integration tests",
            attachments: [Attachment(url: URL(fileURLWithPath: "/tmp/test-plan.md"))],
            customInstructions: "Use the staging environment")

        let queued = RemoteQueuedPrompt(prompt)

        #expect(UUID(uuidString: queued.id) == prompt.id)
        #expect(queued.text == "Run the integration tests")
        #expect(queued.attachments == ["test-plan.md"])
    }

    @Test func anEmptyQueueIsSentAsARealUpdate() throws {
        let update = RemoteUpdate(queued: [])

        #expect(!update.isEmpty)
        let data = try JSONEncoder().encode(update)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["queued"] as? [Any])?.isEmpty == true)
    }

    // The phone draws a call as one row, so it is sent the same verb and argument the
    // desktop spine puts on that row rather than the raw input to work them out from.
    @Test func namesAToolCallTheWayTheDesktopDoes() {
        let command = RemoteTool(
            ToolUse(id: "call-1", name: "Bash",
                    input: #"{"command":"npm run test:unit -- billing"}"#),
            projectPath: "/repo")
        let edit = RemoteTool(
            ToolUse(id: "call-2", name: "Edit",
                    input: #"{"file_path":"/repo/worker/scheduler.ts","old_string":"","new_string":"a\nb"}"#),
            projectPath: "/repo")

        #expect(command.argument == "npm run test:unit -- billing")
        #expect(command.added == nil)
        #expect(edit.argument == "worker/scheduler.ts")
        #expect(edit.added == 2)
    }

    @Test func tellsThePhoneWhatIsBeingAskedAndWhereItWouldRun() {
        let bash = RemotePermission(request(toolName: "Bash", title: "Bash"),
                                    runsIn: "wt/billing-split")
        let edit = RemotePermission(request(toolName: "Edit", title: "Edit"),
                                    runsIn: "lantern-api")

        #expect(bash.kind == "permission")
        #expect(bash.toolName == "Bash")
        #expect(bash.lead == "The agent wants to run:")
        #expect(bash.runsIn == "wt/billing-split")
        #expect(edit.lead == "The agent wants to use Edit:")
        #expect(edit.runsIn == "lantern-api")
    }

    private func request(toolName: String, title: String) -> PermissionRequest {
        PermissionRequest(id: "req-1", toolName: toolName, title: title,
                          subject: "bin/reset-db --seed", detail: "", input: Data(),
                          suggestions: nil, alwaysTitle: "Always allow \(toolName)",
                          questions: [])
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
