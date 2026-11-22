import Foundation
import Testing
@testable import MenuBarApp

// A /btw question is answered on the side. What matters is that it never reaches the
// session's own conversation: no queued prompt, no line in the transcript, and for
// Claude a fork that is never saved.
@MainActor
struct SessionAsideTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    private func runner() -> SessionRunner {
        let runner = SessionRunner(store: store, preferences: testPreferences.store,
                                   paths: [.claudeCode: "/usr/bin/true", .codex: "/usr/bin/true"])
        runner.asides.answer = { _, _ in .success("unused") }
        return runner
    }

    private func startedSession(agent: AgentKind = .claudeCode) throws -> ChatSession {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: agent))
        store.setAgentSessionID("conversation-1", agent: agent, for: session.id)
        store.append(ChatMessage(role: .user, text: "Do the thing"), to: session.id)
        return try #require(store.session(session.id))
    }

    @Test func theQuestionIsWhatComesAfterTheWord() {
        #expect(SessionAside.question(in: "/btw") == "")
        #expect(SessionAside.question(in: "  /BTW what is this? ") == "what is this?")
        #expect(SessionAside.question(in: "/btw\nwhy") == "why")
        #expect(SessionAside.question(in: "/btwx") == nil)
        #expect(SessionAside.question(in: "btw why") == nil)
    }

    @Test func askingNeverTouchesTheConversation() throws {
        let runner = runner()
        let session = try startedSession()
        let before = store.transcript(of: session.id)

        runner.send("/btw which file holds the parser?", sessionID: session.id)

        #expect(runner.queued(session.id).isEmpty)
        #expect(store.transcript(of: session.id) == before)
        #expect(runner.asides.aside(session.id)?.question == "which file holds the parser?")
    }

    @Test func claudeAnswersFromTheConversationAndCodexFromTheChat() async throws {
        let runner = runner()
        let asked = AskedBox()
        runner.asides.answer = { request, _ in
            await asked.add(request)
            return .success("done")
        }
        let claude = try startedSession()
        let codex = try startedSession(agent: .codex)

        runner.send("/btw why?", sessionID: claude.id)
        runner.send("/btw why?", sessionID: codex.id)
        while await asked.requests.count < 2 { await Task.yield() }

        let requests = await asked.requests
        #expect(requests.first { $0.agent == .claudeCode }?.conversationID == "conversation-1")
        #expect(requests.first { $0.agent == .codex }?.conversationID == nil)
        #expect(requests.first { $0.agent == .codex }?.recentChat.contains("Do the thing") == true)
    }

    @Test func anEmptyQuestionOnlyLeavesANote() throws {
        let runner = runner()
        let session = try startedSession()

        runner.send("/btw", sessionID: session.id)

        #expect(runner.asides.aside(session.id) == nil)
        #expect(runner.queued(session.id).isEmpty)
        #expect(store.transcript(of: session.id).last?.role == .system)
    }

    @Test func theForkIsNeverSaved() {
        let arguments = SessionAside.claudeArguments(prompt: "q", resume: "abc", model: "opus",
                                                     addDirectories: ["/other"])
        #expect(arguments.contains("--fork-session"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.firstIndex(of: "--resume").map { arguments[$0 + 1] } == "abc")
        #expect(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] } == "opus")
        #expect(arguments.contains("Edit,Write,MultiEdit,NotebookEdit,Bash"))
    }

    @Test func aRunWithoutTheConversationIsGivenTheChat() {
        let request = SessionAside.Request(question: "why?", agent: .codex, executable: "", searchPath: "",
                                           directories: ["/p"], conversationID: nil,
                                           recentChat: "User: fix it", model: nil)
        #expect(SessionAside.prompt(for: request).contains("User: fix it"))

        var forked = request
        forked.conversationID = "abc"
        #expect(!SessionAside.prompt(for: forked).contains("User: fix it"))
    }

    @Test func aNewQuestionReplacesTheOldAndItsLateAnswer() throws {
        let store = SessionAsideStore()
        store.answer = { _, _ in
            try? await Task.sleep(for: .seconds(60))
            return .success("late")
        }
        let sessionID = UUID()
        let request = SessionAside.Request(question: "first", agent: .claudeCode, executable: "",
                                           searchPath: "", directories: ["/p"], conversationID: nil,
                                           recentChat: "", model: nil)
        store.ask(request, in: sessionID)
        let first = try #require(store.aside(sessionID))
        var second = request
        second.question = "second"
        store.ask(second, in: sessionID)

        store.finish(first.id, outcome: .success("late"), in: sessionID)
        #expect(store.aside(sessionID)?.question == "second")
        #expect(store.aside(sessionID)?.isAnswering == true)

        let current = try #require(store.aside(sessionID))
        store.finish(current.id, outcome: .success("answer"), in: sessionID)
        #expect(store.aside(sessionID)?.state == .answered("answer"))

        store.dismiss(sessionID)
        #expect(store.aside(sessionID) == nil)
    }
}

private actor AskedBox {
    var requests: [SessionAside.Request] = []
    func add(_ request: SessionAside.Request) { requests.append(request) }
}
