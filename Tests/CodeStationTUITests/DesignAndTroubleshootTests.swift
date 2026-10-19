import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The Design tab (the session's Design conversation, its canvas as files to open in
    // the browser, its ambition, approving and implementing), the Troubleshoot tab, and
    // Tools → Troubleshoot for a diagnosis from scratch.
    @MainActor
    @Suite
    struct DesignAndTroubleshootTests {

        private static let replies = """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Drawn it."}]}}'
        """

        private func draw(_ html: String, for session: ChatSession, in tui: TUIHarness) throws {
            let design = try #require(tui.store.designSession(for: session.id))
            let artifact = try #require(tui.store.designArtifactURL(for: design))
            try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(html.utf8).write(to: artifact)
        }

        // Opening the tab starts a Design conversation behind the session, as the GUI
        // does; a prompt written there goes to that conversation, not to the chat.
        @Test func theDesignTabStartsAndDrivesTheConversation() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 24), agentScript: Self.replies)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Checkout page", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("2", []))

            #expect(await tui.waitFor("canvas: nothing drawn yet"), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" DESIGN"), "\(tui.text)")
            #expect(tui.contains("not approved yet"), "\(tui.text)")
            #expect(tui.contains("no build yet"), "\(tui.text)")
            let design = try #require(tui.store.designSession(for: session.id))

            await tui.press(.enter([]))
            await tui.type("A calmer checkout")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("Drawn it."), "\(tui.text)")
            #expect(tui.store.transcript(of: design.id).contains { $0.text == "A calmer checkout" })
            #expect(!tui.store.transcript(of: session.id).contains { $0.text == "A calmer checkout" })

            // Esc leaves the composer, then goes back to the chat.
            await tui.press(.escape, .escape)
            #expect(tui.contains("› write a prompt: enter"), "\(tui.text)")
        }

        // With something on the canvas: `o` opens it in the browser, `A` steps the
        // ambition, `v` approves, and `I` asks for guidance and hands it to the Build.
        @Test func theCanvasOpensInTheBrowserAndIsApprovedAndImplemented() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24), agentScript: Self.replies)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Checkout page", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("2", []))
            #expect(await tui.waitFor("canvas: nothing drawn yet"), "\(tui.text)")

            try draw("<html>Checkout</html>", for: session, in: tui)
            #expect(await tui.waitFor("canvas: Canvas (index.html)"), "\(tui.text)")

            await tui.press(.char("o", []))
            let design = try #require(tui.store.designSession(for: session.id))
            let artifact = try #require(tui.store.designArtifactURL(for: design))
            #expect(tui.launched == [["/usr/bin/open", artifact.absoluteString]])
            #expect(tui.contains("Opened Canvas in the browser."), "\(tui.text)")

            await tui.press(.char("A", []))
            #expect(await tui.waitFor("Ambition: Restrained, from the next turn."), "\(tui.text)")
            #expect(await tui.waitFor("ambition Restrained"), "\(tui.text)")
            #expect(tui.store.session(design.id)?.settings?.designAmbition == .restrained)

            await tui.press(.char("v", []))
            #expect(await tui.waitFor("Approved Design v1."), "\(tui.text)")
            #expect(tui.contains("Design v1 approved"), "\(tui.text)")

            await tui.press(.char("I", []))
            #expect(tui.contains("Implement this Design?"), "\(tui.text)")
            await tui.type("Keep the header")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("Implementation started from Design v1"), "\(tui.text)")
            #expect(await tui.waitFor("BUILD UP TO DATE"), "\(tui.text)")
            #expect(tui.store.transcript(of: session.id).contains {
                $0.text.contains("Additional context:\nKeep the header")
            })
        }

        // The Troubleshoot tab asks the brief of the session it is on: the environments
        // the site file names (a live one warns), the servers each reaches, and the brief
        // goes to the chat, marking the session as troubleshooting.
        @Test func theTroubleshootTabStartsADiagnosis() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30), agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            case "$input" in *'Environment: Prod (prd)'*'Treat this environment as live'*) ;; *) exit 7 ;; esac
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Investigating."}]}}'
            """)
            defer { tui.tearDown() }
            try #"{"environments": [{"name": "dev", "title": "Dev"}, {"name": "prd", "title": "Prod", "danger": true}]}"#
                .write(to: tui.scratch.path("site-defaults.json"), atomically: true, encoding: .utf8)
            try #"{"mcpServers": {"grafana-dev": {"command": "g", "environment": "dev"}, "grafana-prd": {"command": "g", "environment": "prd"}}}"#
                .write(to: tui.scratch.path("mcp.json"), atomically: true, encoding: .utf8)
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Payments", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("3", []))

            #expect(await tui.waitFor("Give your agent a starting point"), "\(tui.text)")
            #expect(tui.contains("Projects: alpha · Agent: Claude Code"), "\(tui.text)")
            #expect(tui.line(containing: "MCP servers")?.text.contains("grafana-dev") == true, "\(tui.text)")
            // Enter with nothing said is refused in the footer.
            await tui.press(.enter([]))
            #expect(tui.contains("Describe the problem or attach evidence to continue."), "\(tui.text)")

            await tui.type("Refunds fail")
            await tui.press(.down([]), .right([]))
            #expect(tui.line(containing: "Environment")?.text.contains("‹ Prod ›") == true, "\(tui.text)")
            #expect(tui.contains("⚠ Prod is live."), "\(tui.text)")
            #expect(tui.line(containing: "MCP servers")?.text.contains("grafana-prd") == true, "\(tui.text)")

            await tui.press(.enter([]))

            #expect(await tui.waitFor("Diagnosis started"), "\(tui.text)")
            #expect(await waitUntil { tui.store.transcript(of: session.id).contains { $0.text == "Investigating." } },
                    "\(tui.store.transcript(of: session.id).map(\.text))")
            #expect(tui.store.session(session.id)?.isTroubleshooting == true)
            #expect(tui.store.session(session.id)?.settings?.allowedMCPServerNames == ["grafana-prd"])
            await tui.press(.escape)
            #expect(await tui.waitFor("TROUBLESHOOT"), "\(tui.topBarText)")
        }

        // Tools → Troubleshoot asks where the diagnosis runs and on which agent, then
        // opens it as a new troubleshooting session.
        @Test func toolsTroubleshootStartsANewDiagnosisSession() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30), agentScript: Self.replies)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Payments", in: alpha)
            try await tui.start()

            await tui.press(.char("G", []), .down([]), .down([]), .enter([]))
            #expect(tui.frame[0].text == " Tools", "\(tui.text)")
            await tui.press(.down([]), .enter([]))

            #expect(await tui.waitFor("Agent diagnosis"), "\(tui.text)")
            #expect(tui.line(containing: "Run in")?.text.contains("‹ alpha ›") == true, "\(tui.text)")
            await tui.press(.down([]), .down([]))
            await tui.type("Logins time out")
            await tui.press(.enter([]))

            #expect(await waitUntil {
                tui.store.sessions.contains { $0.isTroubleshooting && $0.title != "Payments" }
            })
            #expect(await tui.waitFor("TROUBLESHOOT"), "\(tui.text)")
            #expect(await tui.waitFor("Drawn it."), "\(tui.text)")
        }
    }
}
