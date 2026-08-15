import Foundation
import Testing
@testable import MenuBarApp

// Emptying a session's window without giving up the folder it works in. The agent only
// remembers anything because it is handed a resume id, so what is checked here is that
// the id goes and everything else stays.
@MainActor
struct ClearContextTests {

    private func makeStore() -> ProjectStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-tests-\(UUID().uuidString).json").path
        setenv("CONDUCTOR_STORE", path, 1)
        return ProjectStore()
    }

    private func startedSession(in store: ProjectStore,
                                agent: AgentKind = .claudeCode) -> ChatSession {
        let project = store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
        let session = store.newSession(in: project.id, agent: agent)
        store.setAgentSessionID("conversation-1", agent: agent, for: session.id)
        store.append(ChatMessage(role: .user, text: "Do the thing"), to: session.id)
        store.recordUsage(TurnUsage(costUSD: 0.5, inputTokens: 1000, contextWindow: 200_000),
                          from: agent, for: session.id)
        store.recordContext(120_000, contextWindow: 200_000, model: "opus",
                            from: agent, for: session.id)
        return store.session(session.id)!
    }

    @Test func droppingTheResumeIDIsTheWholeOfClearing() throws {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)

        #expect(runner.canClearContext(session.id, store: store))
        #expect(runner.clearContext(session.id, store: store) == .cleared)

        let cleared = try #require(store.session(session.id))
        #expect(cleared.claudeSessionID == nil)
        #expect(cleared.codexSessionID == nil)
        // The session still works where it always did.
        #expect(cleared.projectID == session.projectID)
        #expect(cleared.agent == session.agent)
        #expect(cleared.settings == session.settings)
    }

    // The percentage has to go back to nothing or the clear reads as having done
    // nothing at all. What the session has spent is still spent.
    @Test func theMeterEmptiesButTheBillDoesNot() throws {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)

        runner.clearContext(session.id, store: store)

        let usage = try #require(store.session(session.id)?.usage)
        #expect(usage.contextTokens == 0)
        #expect(usage.contextFraction == 0)
        #expect(usage.contextWindow == 200_000)
        #expect(usage.costUSD == 0.5)
        #expect(usage.inputTokens == 1000)
        #expect(usage.turns == 1)
    }

    // The transcript belongs to the person reading it, not to the agent, so clearing
    // marks the seam instead of throwing the conversation away.
    @Test func theTranscriptSurvivesWithASeam() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)

        runner.clearContext(session.id, store: store)

        let transcript = store.transcript(of: session.id)
        #expect(transcript.count == 2)
        #expect(transcript.first?.text == "Do the thing")
        #expect(transcript.last?.role == .system)
        #expect(transcript.last?.text.contains("Context cleared") == true)
    }

    @Test func aSessionThatNeverRanHasNothingToClear() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let project = store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
        let session = store.newSession(in: project.id)

        #expect(!runner.canClearContext(session.id, store: store))
        #expect(runner.clearContext(session.id, store: store) == .nothingToClear)
        #expect(store.transcript(of: session.id).isEmpty)
    }

    // Codex has no clearing command of its own. It does not need one: it resumes the
    // same way, so it clears the same way.
    @Test func codexClearsTheSameWay() throws {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store, agent: .codex)

        #expect(runner.clearContext(session.id, store: store) == .cleared)
        #expect(try #require(store.session(session.id)).codexSessionID == nil)
    }

    // MARK: - The typed command

    @Test func onlyTheExactWordIsTheAppsOwnCommand() {
        #expect(SessionRunner.isClearCommand("/clear"))
        #expect(SessionRunner.isClearCommand("  /clear  "))
        #expect(SessionRunner.isClearCommand("/Clear"))
        // Real agent commands, which have to travel to the agent untouched.
        #expect(!SessionRunner.isClearCommand("/clear-cache"))
        #expect(!SessionRunner.isClearCommand("/code-review"))
        #expect(!SessionRunner.isClearCommand("/clear the build folder"))
        #expect(!SessionRunner.isClearCommand("clear"))
    }

    @Test func typingItClearsInsteadOfQueueingAPrompt() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)

        runner.send("/clear", sessionID: session.id, store: store)

        #expect(runner.queued(session.id).isEmpty)
        #expect(store.session(session.id)?.claudeSessionID == nil)
        #expect(store.transcript(of: session.id).last?.role == .system)
    }

    // Attachments would be thrown away with the command, so a prompt carrying anything
    // is left to run as one.
    @Test func aClearCarryingAttachmentsIsAnOrdinaryPrompt() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)
        let attachment = Attachment(url: URL(fileURLWithPath: "/tmp/shot.png"))

        runner.send("/clear", attachments: [attachment], sessionID: session.id, store: store)

        #expect(store.session(session.id)?.claudeSessionID == "conversation-1")
    }

    // MARK: - Compacting

    // The CLI writes this when it has replaced the conversation with a summary. The
    // payload here is a real one taken off the wire, underscores and all.
    @Test func readsTheCompactionBoundaryOffTheStream() throws {
        let line = #"""
        {"type":"system","subtype":"compact_boundary","session_id":"abc","compact_metadata":{"trigger":"manual","pre_tokens":32824,"post_tokens":5852,"cumulative_dropped_tokens":52395,"duration_ms":56333}}
        """#
        guard case .compacted(let pre, let post) = try #require(StreamEvent.parse(line).first) else {
            Issue.record("expected a compaction event")
            return
        }
        #expect(pre == 32824)
        #expect(post == 5852)
    }

    // The CLI's own history file spells the same fields in camel case and leaves out the
    // size afterwards, so neither spelling nor completeness can be relied on.
    @Test func readsTheBoundaryWhicheverWayTheKeysAreSpelled() throws {
        let line = #"""
        {"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":30587}}
        """#
        guard case .compacted(let pre, let post) = try #require(StreamEvent.parse(line).first) else {
            Issue.record("expected a compaction event")
            return
        }
        #expect(pre == 30587)
        #expect(post == nil)
    }

    // The summary is the whole conversation now, so its size is how full the window is.
    @Test func theSizeAfterCompactingIsTheNewReading() {
        var usage = SessionUsage()
        usage.noteContext(120_000, contextWindow: 200_000, model: "opus", from: .claudeCode)

        usage.noteContext(5852, contextWindow: nil, model: nil, from: .claudeCode)

        #expect(usage.contextTokens == 5852)
        #expect(usage.contextWindow == 200_000)
    }

    // Without a size afterwards there is nothing honest to show, so the meter comes off
    // the row until a turn measures one.
    @Test func aCompactionThatSaysNoNewSizeRetiresTheReading() {
        var usage = SessionUsage()
        usage.noteContext(120_000, contextWindow: 200_000, model: "opus", from: .claudeCode)

        usage.noteCompacted()

        #expect(usage.contextTokens == 0)
        #expect(usage.contextWindow == 0)
        #expect(usage.contextFraction == nil)
    }

    @Test func theNoticeReportsWhatTheCompactionAchieved() {
        #expect(SessionRunner.compactedNotice(preTokens: 32824, postTokens: 5852)
            == "Context compacted, from 32.8k tokens down to 5.9k.")
        #expect(SessionRunner.compactedNotice(preTokens: 30587, postTokens: nil)
            .contains("30.6k tokens were summarised"))
        #expect(SessionRunner.compactedNotice(preTokens: nil, postTokens: nil)
            .contains("replaced by a summary"))
    }

    // Clearing is the other way round: the window really is empty, so the meter stays on
    // the row and reads zero.
    @Test func clearingKeepsTheMeterAndReadsZero() {
        var usage = SessionUsage()
        usage.noteContext(120_000, contextWindow: 200_000, model: "opus", from: .claudeCode)

        usage.noteCleared()

        #expect(usage.contextWindow == 200_000)
        #expect(usage.contextFraction == 0)
    }

    // Codex compacts automatically, so it is never offered a manual action.
    @Test func onlyClaudeCodeCanCompact() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])

        #expect(runner.canCompactContext(startedSession(in: store).id, store: store))
        #expect(!runner.canCompactContext(startedSession(in: store, agent: .codex).id, store: store))
    }

    @Test func typingCompactOnCodexExplainsAutomaticCompaction() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store, agent: .codex)

        runner.send("/compact", sessionID: session.id, store: store)

        #expect(runner.queued(session.id).isEmpty)
        #expect(store.transcript(of: session.id).last?.text
            == "Codex compacts context automatically. Manual compaction is not available.")
        // The conversation is untouched: compacting is not a quiet clear.
        #expect(store.session(session.id)?.codexSessionID == "conversation-1")
    }

    @Test func onlyTheExactCompactWordIsACommand() {
        #expect(SessionRunner.isCompactCommand("/compact"))
        #expect(SessionRunner.isCompactCommand("  /Compact "))
        #expect(!SessionRunner.isCompactCommand("/compact the logs"))
        #expect(!SessionRunner.isCompactCommand("/compact-db"))
    }

    // The command travels down the pipe as a prompt, but it is not a line of the
    // conversation, so it never appears as one.
    @Test func theCompactCommandIsNotAUserMessage() {
        let command = SessionRunner.QueuedPrompt(text: "/compact", attachments: [],
                                                 customInstructions: nil, isAppCommand: true)
        #expect(command.transcriptMessages.isEmpty)
        #expect(command.prompt == "/compact")

        let typed = SessionRunner.QueuedPrompt(text: "Fix the bug", attachments: [],
                                               customInstructions: nil)
        #expect(typed.transcriptMessages.map(\.role) == [.user])
    }

    // MARK: - The nearly-full nudge

    // The nudge and the meter's red band are the same warning, so they start together.
    @Test func theNudgeStartsWhereTheMeterTurnsRed() {
        #expect(SessionRunner.nearlyFullContext == 0.85)
    }

    // A dismissal is only meant to last until the window is dealt with. One that outlived
    // a clear would hide the warning the next time the session filled up.
    @Test func dealingWithTheWindowBringsTheNudgeBack() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = startedSession(in: store)

        runner.dismissNudge(session.id)
        #expect(runner.isNudgeDismissed(session.id))

        runner.clearContext(session.id, store: store)
        #expect(!runner.isNudgeDismissed(session.id))
    }

    @Test func typingItWithNothingToClearSaysSo() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let project = store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
        let session = store.newSession(in: project.id)

        runner.send("/clear", sessionID: session.id, store: store)

        let transcript = store.transcript(of: session.id)
        #expect(transcript.count == 1)
        #expect(transcript.last?.role == .system)
        #expect(transcript.last?.text.contains("no conversation to clear") == true)
    }
}
