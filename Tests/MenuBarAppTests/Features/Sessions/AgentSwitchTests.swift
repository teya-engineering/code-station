import Foundation
import Testing
@testable import MenuBarApp

// Moving a session to another agent between turns: which access level it lands on, what
// the dialog warns about, what the next agent is handed, and that a failed handover
// leaves the session exactly as it was.
@MainActor
struct AgentSwitchTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    // MARK: - Access

    @Test func accessNeverGetsLooserOnASwitch() {
        #expect(AgentAccess.claudeCode(.auto).nearest(on: .codex) == .codex(.approveForMe))
        #expect(AgentAccess.claudeCode(.acceptEdits).nearest(on: .codex) == .codex(.workspaceWrite))
        #expect(AgentAccess.claudeCode(.manual).nearest(on: .codex) == .codex(.workspaceWrite))
        #expect(AgentAccess.claudeCode(.auto).nearest(on: .copilot) == .copilot(.workspace))
        #expect(AgentAccess.codex(.workspaceWrite).nearest(on: .claudeCode) == .claudeCode(.acceptEdits))
        #expect(AgentAccess.codex(.approveForMe).nearest(on: .claudeCode) == .claudeCode(.auto))
        #expect(AgentAccess.copilot(.workspace).nearest(on: .codex) == .codex(.workspaceWrite))
        #expect(AgentAccess.codex(.approveForMe).nearest(on: .copilot) == .copilot(.workspace))
        // Full access only carries over between the two agents that have it.
        #expect(AgentAccess.codex(.fullAccess).nearest(on: .copilot) == .copilot(.fullAccess))
        #expect(AgentAccess.copilot(.fullAccess).nearest(on: .claudeCode) == .claudeCode(.auto))
    }

    @Test func accessIsWrittenToTheFieldItsAgentReads() {
        var settings = SessionSettings(permissionMode: .manual)
        AgentAccess.codex(.approveForMe).apply(to: &settings)

        #expect(settings.codexSandboxMode == .approveForMe)
        #expect(settings.permissionMode == .manual)
    }

    // MARK: - Warnings

    @Test func onlyFullAccessIsWarnedAbout() {
        let warning = AgentSwitch.fullAccessWarning(for: .copilot)

        #expect(warning.title == "Full access lets Copilot run anything on this Mac")
        #expect(AgentAccess.copilot(.fullAccess).isUnrestricted)
        #expect(!AgentAccess.copilot(.workspace).isUnrestricted)
    }

    // MARK: - What the next agent is handed

    @Test func handoffsRunFromLeastToMost() {
        #expect(AgentHandoff.allCases == [.worktree, .note, .transcript])
    }

    @Test func theAgentTakingOverIsAskedToWriteForItself() {
        let outgoing = AgentSwitch.notePrompt(transcript: "Person:\nShip it", from: .claudeCode, to: .copilot)
        let incoming = AgentSwitch.notePrompt(transcript: "Person:\nShip it", from: .claudeCode,
                                              to: .copilot, writer: .incoming)

        #expect(outgoing.contains("Write a short handoff note for Copilot in Markdown"))
        #expect(incoming.contains("You are Copilot."))
        #expect(incoming.contains("Write a short handoff note for yourself in Markdown"))
        #expect(incoming.contains("<conversation>\nPerson:\nShip it\n</conversation>"))
    }

    @Test func anAgentComingBackOnlySeesWhatHappenedSinceItLeft() {
        var marker = ChatMessage(role: .system, text: "Switched from Claude Code to Codex.")
        marker.marker = SettingsMarker(kind: .agent, agent: .codex, from: .claudeCode, value: "Codex")
        let messages = [
            ChatMessage(role: .user, text: "Fix the scroll"),
            marker,
            ChatMessage(role: .user, text: "Add a test"),
            ChatMessage(role: .assistant, text: "Added one"),
        ]

        #expect(AgentSwitch.unseenMessages(messages, by: .claudeCode).map(\.text)
                == ["Add a test", "Added one"])
        #expect(AgentSwitch.unseenMessages(messages, by: .copilot).count == 4)
    }

    @Test func theTranscriptNamesWhoSaidWhat() {
        var marker = ChatMessage(role: .system, text: "Switched from Claude Code to Codex.")
        marker.marker = SettingsMarker(kind: .agent, agent: .codex, from: .claudeCode, value: "Codex")
        let text = AgentSwitch.plainTranscript([
            ChatMessage(role: .user, text: "Fix the scroll"),
            ChatMessage(role: .assistant, text: "Fixed"),
            marker,
            ChatMessage(role: .assistant, text: "Tested"),
        ], agent: .claudeCode, projectPath: "/tmp")

        #expect(text.contains("Person:\nFix the scroll"))
        #expect(text.contains("Claude Code:\nFixed"))
        #expect(text.contains("Codex:\nTested"))
    }

    @Test func aLongTranscriptKeepsItsEnd() {
        let messages = (0..<50).map { ChatMessage(role: .user, text: "Prompt \($0)") }
        let text = AgentSwitch.plainTranscript(messages, agent: .codex, projectPath: "/tmp", limit: 100)

        #expect(text.hasPrefix("[Older messages were cut to fit.]"))
        #expect(text.hasSuffix("Prompt 49"))
    }

    @Test func handingOverOnlyTheWorktreeSendsNothing() throws {
        #expect(AgentSwitch.handoffPrompt(.worktree, text: "", from: .claudeCode, to: .codex,
                                          returning: false) == nil)
        let prompt = try #require(AgentSwitch.handoffPrompt(.note, text: "## Goal\nShip it",
                                                            from: .claudeCode, to: .codex,
                                                            returning: false))
        #expect(prompt.contains("<handoff-note>\n## Goal\nShip it\n</handoff-note>"))
        #expect(prompt.contains("Do not change anything yet."))
    }

    @Test func aNoteIsTakenOutOfAnyWrapping() {
        #expect(AgentSwitchDraft.cleanedNote("```markdown\n## Goal\nShip it\n```") == "## Goal\nShip it")
        #expect(AgentSwitchDraft.cleanedNote("Here is the note:\n\n## Goal\nShip it") == "## Goal\nShip it")
        #expect(AgentSwitchDraft.cleanedNote("   ") == nil)
    }

    @Test func thePlainNoteStartsFromTheFirstAsk() {
        let note = AgentSwitch.plainNote([
            ChatMessage(role: .user, text: "Stop the transcript jumping\nIt happens on queue"),
            ChatMessage(role: .user, text: "Now add a test"),
        ], projectPath: "/tmp")

        #expect(note.hasPrefix("## Goal\nStop the transcript jumping\n"))
        #expect(note.contains("- Asked: Now add a test"))
    }

    @Test func eachCLIsVersionIsReadTheWayItPrintsIt() {
        #expect(AgentSwitch.versionNumber(from: "2.1.220 (Claude Code)", agent: .claudeCode) == "2.1.220")
        #expect(AgentSwitch.versionNumber(from: "codex-cli 0.141.2", agent: .codex) == "0.141.2")
        #expect(AgentSwitch.versionNumber(from: "GitHub Copilot CLI 1.0.83.\nRun copilot update",
                                          agent: .copilot) == "1.0.83")
    }

    // MARK: - The session

    @Test func aSessionRemembersEveryAgentItRanOn() throws {
        let session = store.newSession(in: project.id)
        store.switchAgent(session.id, to: .codex, settings: SessionSettings(model: "gpt-5.5-codex"),
                          record: AgentSwitchRecord(from: .claudeCode, to: .codex, date: .now,
                                                    model: "opus", effort: "high"))
        store.switchAgent(session.id, to: .claudeCode, settings: SessionSettings(model: "opus"),
                          record: AgentSwitchRecord(from: .codex, to: .claudeCode, date: .now,
                                                    model: "gpt-5.5-codex", effort: nil))

        let switched = try #require(store.session(session.id))
        #expect(switched.agent == .claudeCode)
        #expect(switched.agentsUsed == [.claudeCode, .codex])
        #expect(switched.lastRun(of: .claudeCode)?.effort == "high")
        #expect(switched.lastRun(of: .codex)?.model == "gpt-5.5-codex")

        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(switched))
        #expect(decoded.agentSwitches == switched.agentSwitches)
    }

    @Test func aSessionSavedBeforeSwitchingStillReads() throws {
        let saved = #"{"id":"\#(UUID().uuidString)","projectID":"\#(project.id.uuidString)","agent":"codex"}"#
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(saved.utf8))

        #expect(session.agentSwitches.isEmpty)
        #expect(session.agentsUsed == [.codex])
    }

    @Test func rewindingStopsAtASwitch() {
        let session = store.newSession(in: project.id)
        var before = ChatMessage(role: .user, text: "Before")
        before.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        store.append(before, to: session.id)
        var marker = ChatMessage(role: .system, text: "Switched.")
        marker.marker = SettingsMarker(kind: .agent, agent: .claudeCode, from: .codex, value: "Claude Code")
        store.append(marker, to: session.id)
        var after = ChatMessage(role: .user, text: "After")
        after.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        store.append(after, to: session.id)

        #expect(store.rewindableMessageIDs(in: session.id) == [after.id])
    }

    // MARK: - The note

    private func draft(to target: AgentKind, paths: [AgentKind: String]) throws -> AgentSwitchDraft {
        let runner = SessionRunner(store: store, preferences: testPreferences.store, paths: paths)
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Stop the transcript jumping"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: "Pinned the scroll position."), to: session.id)
        return try #require(AgentSwitchDraft(sessionID: session.id, to: target, store: store, runner: runner))
    }

    @Test func theAppsOwnNoteIsReadyAtOnce() throws {
        let draft = try draft(to: .codex, paths: [:])

        draft.draftNote(by: .app)

        #expect(!draft.isDrafting)
        #expect(draft.writer == .app)
        #expect(draft.silentWriter == nil)
        #expect(draft.note.hasPrefix("## Goal\nStop the transcript jumping\n"))
        #expect(draft.canStart)
    }

    @Test func aWriterThatDoesNotAnswerLeavesThePlainListAndSaysSo() async throws {
        // Claude Code is not installed here, so it cannot be asked.
        let draft = try draft(to: .codex, paths: [:])

        draft.draftNote()
        #expect(draft.isDrafting)
        #expect(!draft.canStart)

        #expect(await waitUntil { !draft.isDrafting })
        #expect(draft.silentWriter == .outgoing)
        #expect(draft.writer == .app)
        #expect(draft.note.hasPrefix("## Goal\nStop the transcript jumping\n"))
        #expect(draft.canStart)
    }

    @Test func anotherHandoffCanGoWhileTheNoteIsBeingWritten() throws {
        let draft = try draft(to: .codex, paths: [:])

        draft.draftNote()
        defer { draft.cancel() }

        #expect(draft.isDrafting)
        draft.handoff = .transcript
        #expect(draft.canStart)
        draft.handoff = .worktree
        #expect(draft.canStart)
    }

    @Test func eachHandoffSaysHowBigItIs() throws {
        let draft = try draft(to: .codex, paths: [:])
        draft.draftNote(by: .app)

        #expect(draft.tokens(of: .worktree) == 0)
        #expect(draft.tokens(of: .note) == AgentSwitch.estimatedTokens(draft.note))
        #expect(draft.tokens(of: .transcript) == AgentSwitch.estimatedTokens(draft.transcriptText))
        #expect(draft.messageCount == 2)
        #expect(draft.transcriptTail.last == "Pinned the scroll position.")
    }

    // MARK: - Handing over

    private func fakeCLI(printing version: String) throws -> String {
        let url = scratch.path("codex-\(UUID().uuidString)")
        try "#!/bin/sh\necho '\(version)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func aMissingCLILeavesTheSessionAsItWas() async throws {
        let runner = SessionRunner(store: store, preferences: testPreferences.store,
                                   paths: [.claudeCode: "/usr/bin/true"])
        let session = store.newSession(in: project.id)
        let draft = try #require(AgentSwitchDraft(sessionID: session.id, to: .codex, store: store,
                                                  runner: runner))
        draft.handoff = .worktree
        var finished = false

        draft.start { finished = true }

        #expect(await waitUntil { draft.isFailed })
        #expect(draft.failure?.title == "Codex is not installed")
        #expect(draft.failure?.command == AgentKind.codex.installHint)
        #expect(!finished)
        #expect(store.session(session.id)?.agent == .claudeCode)
        #expect(store.transcript(of: session.id).isEmpty)
    }

    @Test func anOutdatedCLIIsCaughtBeforeAnythingChanges() async throws {
        let runner = SessionRunner(store: store, preferences: testPreferences.store,
                                   paths: [.codex: try fakeCLI(printing: "codex-cli 0.141.2")])
        let session = store.newSession(in: project.id)
        let draft = try #require(AgentSwitchDraft(sessionID: session.id, to: .codex, store: store,
                                                  runner: runner))
        draft.handoff = .worktree

        draft.start {}

        #expect(await waitUntil { draft.isFailed })
        #expect(draft.failure?.title == "Codex 0.141.2 is too old for Code Station")
        #expect(store.session(session.id)?.agent == .claudeCode)
    }

    @Test func aSwitchMovesTheSessionAndMarksTheTranscript() async throws {
        let runner = SessionRunner(store: store, preferences: testPreferences.store,
                                   paths: [.codex: try fakeCLI(printing: "codex-cli 0.152.0")])
        let session = store.newSession(in: project.id)
        store.setSettings(SessionSettings(permissionMode: .auto), for: session.id)
        let draft = try #require(AgentSwitchDraft(sessionID: session.id, to: .codex, store: store,
                                                  runner: runner))
        draft.handoff = .worktree
        #expect(draft.access == .codex(.approveForMe))
        var finished = false

        draft.start { finished = true }

        #expect(await waitUntil { finished })
        let switched = try #require(store.session(session.id))
        #expect(switched.agent == .codex)
        #expect(switched.settings?.codexSandboxMode == .approveForMe)
        #expect(switched.settings?.permissionMode == .auto)
        #expect(switched.agentSwitches.map(\.from) == [.claudeCode])
        let marker = try #require(store.transcript(of: session.id).last?.marker)
        #expect(marker.kind == .agent)
        #expect(marker.from == .claudeCode)
        #expect(marker.agent == .codex)
        // Nothing was handed over, so no turn was started on the new agent.
        #expect(runner.queued(session.id).isEmpty)
        #expect(!runner.state(session.id).isBusy)
    }
}
