import Foundation
import Testing
@testable import MenuBarApp

// Winding a conversation back to an earlier prompt, and forking a new session from one.
// Both rest on the checkpoint a prompt carries: the resume ids as they stood before
// that turn ran.
@MainActor
struct RewindTests {

    private func makeStore() -> ProjectStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-tests-\(UUID().uuidString).json").path
        setenv("CONDUCTOR_STORE", path, 1)
        return ProjectStore()
    }

    private func makeSession(in store: ProjectStore) -> ChatSession {
        let project = store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
        return store.newSession(in: project.id)
    }

    // A conversation of two Claude turns, with the resume id the second turn started
    // from recorded on its prompt.
    private func twoTurns(in store: ProjectStore, session: ChatSession)
        -> (first: ChatMessage, second: ChatMessage) {
        var first = ChatMessage(role: .user, text: "Build the thing")
        first.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        store.append(first, to: session.id)
        store.append(ChatMessage(role: .assistant, text: "Built it"), to: session.id)
        store.setAgentSessionID("claude-1", agent: .claudeCode, for: session.id)

        var second = ChatMessage(role: .user, text: "Now break it")
        second.checkpoint = ConversationCheckpoint(agent: .claudeCode,
                                                   claudeSessionID: "claude-1")
        store.append(second, to: session.id)
        store.append(ChatMessage(role: .assistant, text: "Broke it"), to: session.id)
        store.setAgentSessionID("claude-2", agent: .claudeCode, for: session.id)
        return (first, second)
    }

    @Test func aPromptThatStartsATurnRecordsWhereTheConversationStood() throws {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = makeSession(in: store)
        store.setAgentSessionID("claude-1", agent: .claudeCode, for: session.id)

        // The turn cannot start without a CLI on PATH, but the prompt is already in the
        // transcript by then, checkpoint and all.
        runner.send("Do the thing", sessionID: session.id, store: store)

        let prompt = try #require(store.transcript(of: session.id).first)
        #expect(prompt.checkpoint == ConversationCheckpoint(agent: .claudeCode,
                                                            claudeSessionID: "claude-1"))
    }

    @Test func rewindingRestoresTheConversationAndTheComposer() throws {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = makeSession(in: store)
        let (first, second) = twoTurns(in: store, session: session)

        #expect(runner.canRewind(to: second.id, sessionID: session.id, store: store))
        runner.rewind(to: second.id, sessionID: session.id, store: store)

        // The discarded turns are gone, a note marks the seam, and the next turn
        // resumes the conversation as it stood before the second prompt.
        let transcript = store.transcript(of: session.id)
        #expect(transcript.map(\.text).prefix(2) == [first.text, "Built it"])
        #expect(transcript.last?.role == .system)
        #expect(transcript.contains { $0.id == second.id } == false)
        #expect(store.session(session.id)?.claudeSessionID == "claude-1")
        #expect(runner.draft(session.id).text == "Now break it")
    }

    @Test func rewindingToTheFirstPromptStartsOver() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = makeSession(in: store)
        let (first, _) = twoTurns(in: store, session: session)

        runner.rewind(to: first.id, sessionID: session.id, store: store)

        // Nothing had been said before the first prompt, so there is nothing to resume.
        #expect(store.session(session.id)?.claudeSessionID == nil)
        #expect(runner.draft(session.id).text == "Build the thing")
    }

    // Codex reuses one thread for the whole conversation, so a Codex turn cannot be
    // wound back - and neither can anything before it, because the thread already
    // carries what came after.
    @Test func aCodexTurnSealsItselfAndEverythingBeforeIt() {
        let store = makeStore()
        let session = makeSession(in: store)

        var first = ChatMessage(role: .user, text: "One")
        first.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        store.append(first, to: session.id)
        var second = ChatMessage(role: .user, text: "Two")
        second.checkpoint = ConversationCheckpoint(agent: .codex)
        store.append(second, to: session.id)
        var third = ChatMessage(role: .user, text: "Three")
        third.checkpoint = ConversationCheckpoint(agent: .claudeCode,
                                                  codexSessionID: "thread-1")
        store.append(third, to: session.id)

        #expect(store.rewindableMessageIDs(in: session.id) == [third.id])
    }

    // A prompt written before checkpoints existed marks no point to go back to.
    @Test func promptsWithoutACheckpointCannotBeRewoundTo() {
        let store = makeStore()
        let runner = SessionRunner(paths: [:])
        let session = makeSession(in: store)
        let prompt = ChatMessage(role: .user, text: "Old prompt")
        store.append(prompt, to: session.id)

        #expect(!runner.canRewind(to: prompt.id, sessionID: session.id, store: store))
    }

    @Test func forkingCarriesTheConversationUpToThePrompt() throws {
        let store = makeStore()
        let session = makeSession(in: store)
        let (first, second) = twoTurns(in: store, session: session)
        store.renameSession(session.id, to: "Original")

        #expect(store.canForkSession(session.id, before: second.id))
        let fork = try #require(store.forkSession(session.id, before: second.id))

        // The fork holds the first turn and resumes the id the second started from,
        // while the original keeps everything.
        let forked = store.transcript(of: fork.id)
        #expect(forked.map(\.text).prefix(2) == [first.text, "Built it"])
        #expect(forked.last?.role == .system)
        #expect(store.session(fork.id)?.claudeSessionID == "claude-1")
        #expect(store.session(fork.id)?.title == "Original · fork")
        #expect(store.transcript(of: session.id).count == 4)
        #expect(store.session(session.id)?.claudeSessionID == "claude-2")
        #expect(store.selection == .session(fork.id))
    }

    // A worktree session is tied to a checkout the fork would not have.
    @Test func worktreeSessionsDoNotFork() {
        let store = makeStore()
        let project = store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
        let session = store.newSession(in: project.id, worktreePath: "/tmp/worktree",
                                       worktreeBranch: "branch")
        var prompt = ChatMessage(role: .user, text: "One")
        prompt.checkpoint = ConversationCheckpoint(agent: .claudeCode)
        store.append(prompt, to: session.id)

        #expect(!store.canForkSession(session.id, before: prompt.id))
    }

    // A Codex conversation lives in one shared rollout that two sessions would write
    // over each other in.
    @Test func aCodexConversationDoesNotFork() {
        let store = makeStore()
        let session = makeSession(in: store)
        var prompt = ChatMessage(role: .user, text: "One")
        prompt.checkpoint = ConversationCheckpoint(agent: .claudeCode,
                                                   codexSessionID: "thread-1")
        store.append(prompt, to: session.id)

        #expect(!store.canForkSession(session.id, before: prompt.id))
    }
}
