import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The top bar over an open session, as the GUI's identity deck draws it: the container
    // and title, the state with its elapsed time, the agents at work and the facts, with
    // the context bar under it. Narrow, the facts fold into a Details entry.
    @MainActor
    @Suite
    struct TopBarTests {

        // Home has nothing for the top bar: it keeps its one empty row, and Home starts
        // under it.
        @Test func homeKeepsOneEmptyTopBarRow() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            #expect(tui.main[0].text.trimmingCharacters(in: .whitespaces).isEmpty, "\(tui.text)")
            #expect(tui.main[1].text.hasPrefix(" Home"), "\(tui.text)")
        }

        // Wide enough, every fact sits on the bar beside the state.
        @Test func aWideBarShowsIdentityStateAgentsAndFacts() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 20))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "one\n"])
            let session = try tui.store.insertSession(in: alpha.id,
                                                      seed: .init(agent: .claudeCode, isTroubleshooting: true)).get()
            tui.store.renameSession(session.id, to: "Why is login slow")
            tui.store.append(ChatMessage(role: .user, text: "Look into it", date: Date(timeIntervalSinceNow: -600)),
                             to: session.id)
            let reviewer = ToolUse(id: "reviewer", name: "Task",
                                   input: #"{"subagent_type":"reviewer","description":"review"}"#,
                                   result: "it broke", isError: true, startedAt: Date(timeIntervalSinceNow: -300))
            tui.store.append(ChatMessage(role: .assistant, tools: [reviewer], date: Date(timeIntervalSinceNow: -300)),
                             to: session.id)
            tui.store.recordUsage(TurnUsage(costUSD: 0.42, contextWindow: 200_000, model: "opus"),
                                  from: .claudeCode, for: session.id)
            tui.store.recordContext(50_000, contextWindow: 200_000, model: "opus", from: .claudeCode,
                                    for: session.id)
            tui.store.notePullRequest(PullRequest(number: 12, url: "https://github.com/teya/alpha/pull/12"),
                                      for: session.id)
            try "one\ntwo\n".write(to: tui.scratch.path("alpha/README.md"), atomically: true, encoding: .utf8)
            try await tui.start()

            await tui.press(.enter([]))

            #expect(await waitUntil { tui.topBarText.contains("1 file +1 −0") }, "\(tui.topBarText)")
            let bar = try #require(tui.topBar.first)
            #expect(bar.text.hasPrefix(" ■ alpha / TROUBLESHOOT Why is login slow"), "\(bar.text)")
            #expect(bar.style(of: "alpha")?.bold == true)
            #expect(bar.style(of: "TROUBLESHOOT")?.foreground == .basic(35))
            #expect(bar.text.contains("IDLE · 5m"), "\(bar.text)")
            #expect(bar.text.contains("1 agent failed"), "\(bar.text)")
            #expect(bar.style(of: "1 agent failed")?.foreground == .basic(31))
            #expect(bar.text.hasSuffix("⎇ main · 1 file +1 −0 · #12 · Opus · 25% context · $0.42"), "\(bar.text)")
            #expect(!bar.text.contains("Details"))
            // The transcript starts under the bar rather than repeating its title.
            #expect(tui.mainLine(containing: "Look into it") != nil, "\(tui.mainText)")
            #expect(!tui.mainPane.contains { $0.text.contains("Why is login slow") }, "\(tui.mainText)")
        }

        // Narrow, the facts give way to a Details entry, and D opens them in the main pane.
        @Test func aNarrowBarFoldsTheFactsIntoDetails() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 90, rows: 20))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha, ago: 120)
            tui.store.recordUsage(TurnUsage(costUSD: 1.5, contextWindow: 100_000, model: "sonnet"),
                                  from: .claudeCode, for: session.id)
            tui.store.recordContext(40_000, contextWindow: 100_000, model: "sonnet", from: .claudeCode,
                                    for: session.id)
            try await tui.start()

            await tui.press(.enter([]))

            let bar = try #require(tui.topBar.first)
            #expect(bar.text.hasPrefix(" ■ alpha / Fix the"), "\(bar.text)")
            #expect(bar.text.contains("IDLE · 2m"), "\(bar.text)")
            #expect(bar.text.hasSuffix("Details (D)"), "\(bar.text)")
            #expect(!bar.text.contains("Sonnet"))

            await tui.press(.char("D", []))

            let model = try #require(tui.mainLine(containing: "MODEL"), "\(tui.mainText)")
            #expect(model.text.contains("Sonnet"))
            #expect(tui.mainLine(containing: "CONTEXT")?.text.contains("40% full") == true, "\(tui.mainText)")
            #expect(tui.mainLine(containing: "COST")?.text.contains("$1.50") == true, "\(tui.mainText)")
            #expect(tui.topBar.first?.text.contains("Fix the") == true)

            await tui.press(.escape)

            #expect(tui.mainLine(containing: "MODEL") == nil, "\(tui.mainText)")
            #expect(tui.contains("› write a prompt: enter"), "\(tui.text)")
        }

        // The context bar fills with the window, green, then amber from 70%, then red from
        // 85% for an agent that asks for permissions.
        @Test(arguments: [(0.5, 32), (0.75, 33), (0.9, 31)])
        func theContextBarFillsWithTheWindow(_ fraction: Double, _ colour: Int) async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 20))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            tui.store.recordContext(Int(fraction * 100_000), contextWindow: 100_000, model: "opus",
                                    from: .claudeCode, for: session.id)
            try await tui.start()

            await tui.press(.enter([]))

            let gauge = try #require(tui.topBar.dropFirst().first, "\(tui.text)")
            let width = gauge.text.count
            let filled = gauge.text.count { $0 == "━" }
            #expect(filled == Int((fraction * Double(width)).rounded()), "\(gauge.text)")
            #expect(gauge.text.allSatisfy { $0 == "━" || $0 == "─" }, "\(gauge.text)")
            #expect(gauge.style(of: "━")?.foreground == .basic(colour))
        }

        // Without a reading the bar under the deck is an empty track.
        @Test func noContextReadingLeavesAnEmptyTrack() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.enter([]))

            let gauge = try #require(tui.topBar.dropFirst().first)
            #expect(!gauge.text.isEmpty && gauge.text.allSatisfy { $0 == "─" }, "\(tui.topBarText)")
        }

        // Cost shows for an agent that shows it, and not when the shared settings hide it
        // or the agent reports none.
        @Test func costShowsOnlyForAgentsThatShowIt() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 20))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let claude = try tui.addSession("Claude work", in: alpha, ago: 300)
            tui.store.recordUsage(TurnUsage(costUSD: 0.42, model: "opus"), from: .claudeCode, for: claude.id)
            let codex = try tui.addSession("Codex work", in: alpha, agent: .codex, ago: 200)
            tui.store.recordUsage(TurnUsage(costUSD: 0, model: "gpt-5.6-sol"), from: .codex, for: codex.id)
            let hidden = try tui.addSession("Copilot work", in: alpha, agent: .copilot, ago: 100)
            tui.store.recordUsage(TurnUsage(costUSD: 0.9, model: "gpt-5"), from: .copilot, for: hidden.id)
            Preferences.setShowCost(false, for: .copilot, in: tui.preferences)
            try await tui.start()

            try await open("Claude work", in: tui)
            #expect(tui.topBar.first?.text.hasSuffix("Opus · $0.42") == true, "\(tui.topBarText)")

            try await open("Codex work", in: tui)
            #expect(tui.topBar.first?.text.hasSuffix("Sol") == true, "\(tui.topBarText)")
            #expect(tui.topBar.first?.text.contains("$") == false)

            try await open("Copilot work", in: tui)
            #expect(tui.topBar.first?.text.contains("$") == false, "\(tui.topBarText)")
        }

        // The elapsed time of a running turn counts up on its own, with no key pressed.
        @Test func theElapsedTimeTicksWhileRunning() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            sleep 60
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Long job", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Go")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains("RUNNING · ") }, "\(tui.topBarText)")
            #expect(tui.topBar.first?.text.contains(#/RUNNING · \d+s/#) == true, "\(tui.topBarText)")

            tui.clockAhead = 185

            #expect(await waitUntil(timeout: .seconds(5)) { tui.topBarText.contains("RUNNING · 3m") },
                    "\(tui.topBarText)")
        }

        private func open(_ title: String, in tui: TUIHarness) async throws {
            await tui.press(.escape)
            await tui.press(.char("g", []))
            for _ in 0..<8 where tui.sidebarLine(containing: "▸ │ \(title)") == nil {
                await tui.press(.down([]))
            }
            try #require(tui.sidebarLine(containing: "▸ │ \(title)") != nil, "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.topBarText.contains(title) }, "\(tui.topBarText)")
        }
    }
}
