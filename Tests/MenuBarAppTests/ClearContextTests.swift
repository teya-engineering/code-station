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
