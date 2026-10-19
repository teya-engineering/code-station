import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// A question asked on the Changes screen is answered there by a side copy of the session
// and never reaches the main chat. Only a change made from its answer goes to the agent,
// with the review, and on its own words unless the person ticks to send the question too.
@MainActor
struct ReviewQuestionTests {

    private let context = QuestionContext(agent: .claudeCode, executable: "/usr/bin/true", directory: "/repo",
                                          repositories: [ReviewRepository(root: "/repo", name: "App")],
                                          conversationID: "main-session", recentChat: "")

    private func question(_ text: String = "What is this for?") -> ReviewQuestion {
        ReviewQuestion(root: "/repo", path: "App.swift", anchor: DiffAnchor(side: .new, line: 11),
                       excerpt: "let first = items.first!", agent: .claudeCode, question: text)
    }

    // A store whose side copy hands back canned replies and records what it was asked.
    private func store(replies: [Result<SideQuestion.Reply, SecondOpinion.Failure>],
                       asked: Asked = Asked()) -> ReviewCommentStore {
        let store = ReviewCommentStore(url: nil)
        let queue = Replies(replies)
        store.answerQuestion = { request, activity in
            activity("Reading App.swift")
            asked.append(request)
            return queue.next()
        }
        return store
    }

    @Test func askingAnswersInTheThreadAndAddsNothingToTheReview() async {
        let asked = Asked()
        let store = store(replies: [.success(.init(answer: "It is the first item.", suggestion: nil, forkID: "fork-1"))],
                          asked: asked)
        let session = UUID()
        let question = question()

        store.ask(question, context: context, in: session)
        #expect(store.question(question.id, in: session)?.status == .answering)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .answered })

        let answered = store.question(question.id, in: session)
        #expect(answered?.exchanges.first?.answer == "It is the first item.")
        #expect(answered?.forkID == "fork-1")
        #expect(store.comments(session).isEmpty)
        #expect(store.rounds(session).isEmpty)
        #expect(asked.requests.first?.context.conversationID == "main-session")
    }

    @Test func aFollowUpGoesOnInTheSameSideCopy() async {
        let asked = Asked()
        let store = store(replies: [.success(.init(answer: "First.", suggestion: nil, forkID: "fork-1")),
                                    .success(.init(answer: "Second.", suggestion: nil, forkID: nil))],
                          asked: asked)
        let session = UUID()
        let question = question()
        store.ask(question, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .answered })

        store.followUp("And why?", to: question.id, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.exchanges.last?.answer == "Second." })
        #expect(asked.requests.last?.question.forkID == "fork-1")
        #expect(asked.requests.last?.question.exchanges.count == 2)
        #expect(store.question(question.id, in: session)?.forkID == "fork-1")
    }

    @Test func aFailedAnswerSaysWhyAndCanBeTriedAgain() async {
        let store = store(replies: [.failure(.init(message: "It took longer than 3 minutes.")),
                                    .success(.init(answer: "Now it works.", suggestion: nil, forkID: nil))])
        let session = UUID()
        let question = question()
        store.ask(question, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .failed })
        #expect(store.question(question.id, in: session)?.failure == "It took longer than 3 minutes.")

        store.retryQuestion(question.id, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .answered })
        #expect(store.question(question.id, in: session)?.exchanges.count == 1)

        store.deleteQuestion(question.id, in: session)
        #expect(store.questions(session).isEmpty)
    }

    @Test func aMissingAgentFailsAtOnce() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        var context = context
        context.executable = nil
        let question = question()
        store.ask(question, context: context, in: session)
        #expect(store.question(question.id, in: session)?.failure == "Claude Code is not installed.")
    }

    @Test func aSuggestionBecomesAChangeThatCarriesTheQuestion() async throws {
        let store = store(replies: [.success(.init(answer: "It is a sample.", suggestion: "Say it is a sample.",
                                                   forkID: nil))])
        let session = UUID()
        let question = question("What is this?")
        store.ask(question, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .answered })

        let change = try #require(store.makeChange(from: question.id, in: session))
        #expect(change.body == "Say it is a sample.")
        #expect(change.kind == .change)
        #expect(store.kept(session).map(\.id) == [change.id])
        let prompt = ReviewPrompt.feedback(store.kept(session))
        #expect(prompt.contains("Say it is a sample.\n\nWhy: I asked \"What is this?\" and the answer was: It is a sample."))

        store.setSendsQuestion(false, change: change.id, in: session)
        #expect(!ReviewPrompt.feedback(store.kept(session)).contains("Why:"))

        store.takeOutOfReview(question.id, in: session)
        #expect(store.comments(session).isEmpty)
        #expect(store.question(question.id, in: session)?.changeID == nil)
    }

    @Test func aSentChangeIsFoundInItsRound() async throws {
        let store = store(replies: [.success(.init(answer: "A.", suggestion: "Do B.", forkID: nil))])
        store.readFile = { _ in nil }
        let session = UUID()
        let question = question()
        store.ask(question, context: context, in: session)
        #expect(await waitUntil { store.question(question.id, in: session)?.status == .answered })
        let change = try #require(store.makeChange(from: question.id, in: session))

        store.recordRound([change], prompt: ReviewPrompt.feedback([change]), note: "", roots: [], in: session)
        #expect(store.comment(change.id, in: session) == nil)
        #expect(store.round(sending: change.id, in: session) != nil)
        #expect(store.questions(session).count == 1)
    }

    @Test func aQuestionCutOffByQuittingLoadsAsFailed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        let questionsURL = url.deletingPathExtension().appendingPathExtension("questions").appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: questionsURL)
        }
        let session = UUID()
        let store = ReviewCommentStore(url: url)
        store.answerQuestion = { _, _ in
            try? await Task.sleep(for: .seconds(60))
            return .failure(.init(message: "never"))
        }
        let question = question()
        store.ask(question, context: context, in: session)
        store.flush()

        let reopened = ReviewCommentStore(url: url)
        #expect(reopened.question(question.id, in: session)?.status == .failed)
        #expect(reopened.question(question.id, in: session)?.failure == "The app quit before it answered.")
        reopened.remove(session)
        reopened.flush()
        #expect(!FileManager.default.fileExists(atPath: questionsURL.path))
    }

    @Test func theSuggestedChangeIsTakenOffTheEndOfTheAnswer() {
        let read = SideQuestion.read("It is a sample.\n\nSuggested change: Say it is a sample to copy.\n")
        #expect(read.answer == "It is a sample.")
        #expect(read.suggestion == "Say it is a sample to copy.")

        let plain = SideQuestion.read("It is a sample. Nothing to change.")
        #expect(plain.answer == "It is a sample. Nothing to change.")
        #expect(plain.suggestion == nil)
    }

    @Test func claudeForksTheSessionInPlanModeAndCannotWrite() {
        let first = SideQuestion.claudeArguments(prompt: "Q", resume: "main", fork: true)
        #expect(first.contains("--fork-session"))
        #expect(first.firstIndex(of: "--resume").map { first[$0 + 1] } == "main")
        #expect(first.firstIndex(of: "--permission-mode").map { first[$0 + 1] } == "plan")
        #expect(first.firstIndex(of: "--disallowedTools").map { first[$0 + 1] }?.contains("Write") == true)
        #expect(first.contains("--strict-mcp-config"))

        let followUp = SideQuestion.claudeArguments(prompt: "Q", resume: "fork-1", fork: false)
        #expect(!followUp.contains("--fork-session"))
        #expect(followUp.firstIndex(of: "--resume").map { followUp[$0 + 1] } == "fork-1")
    }

    @Test func aReadOnlyRunIsGivenTheChatTheDiffAndTheThreadSoFar() {
        var question = question("What is this?")
        question.exchanges[0].answer = "The first item."
        question.exchanges.append(.init(question: "Can it be empty?"))
        let patch = SecondOpinion.Patch(root: "/repo", path: "App.swift", label: "App.swift", text: "+let first = items.first!")
        let prompt = SideQuestion.readOnlyPrompt(question, patches: [patch], recentChat: "User: Add a first item",
                                                 repositories: [ReviewRepository(root: "/repo", name: "App")])
        #expect(prompt.contains("User: Add a first item"))
        #expect(prompt.contains("File: App.swift\n+let first = items.first!"))
        #expect(prompt.contains("It is about App.swift, line 11."))
        #expect(prompt.contains("I asked: What is this?\nYou answered: The first item."))
        #expect(prompt.contains("My question: Can it be empty?"))
        #expect(prompt.contains("Do not change any files"))
    }

    @Test func aForkIsOnlyToldThePlaceAndTheQuestion() {
        let prompt = SideQuestion.forkPrompt(question("What is this?"))
        #expect(prompt.contains("side copy of our conversation"))
        #expect(prompt.contains("It is about App.swift, line 11.\n```\nlet first = items.first!\n```"))
        #expect(prompt.contains("My question: What is this?"))

        var followed = question()
        followed.exchanges[0].answer = "A."
        followed.exchanges.append(.init(question: "And then?"))
        #expect(SideQuestion.forkPrompt(followed).hasPrefix("A follow-up on the same question: And then?"))
    }

    @Test func theRecentChatKeepsTheNewestTurnsWithinItsBudget() {
        let messages = [ChatMessage(role: .user, text: String(repeating: "a", count: 50)),
                        ChatMessage(role: .assistant, text: "Done."),
                        ChatMessage(role: .user, text: "Now the tests.")]
        let chat = SideQuestion.recentChat(messages, budget: 40)
        #expect(chat == "Agent: Done.\n\nUser: Now the tests.")
    }

    @Test func aForkReportsItsOwnSessionID() {
        let output = #"{"type":"system","subtype":"init","session_id":"fork-9"}"# + "\n"
            + #"{"type":"result","result":"Answer"}"#
        #expect(SideQuestion.sessionID(in: output) == "fork-9")
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SideQuestion.Request] = []

    var requests: [SideQuestion.Request] { lock.withLock { list } }

    func append(_ request: SideQuestion.Request) { lock.withLock { list.append(request) } }
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<SideQuestion.Reply, SecondOpinion.Failure>]

    init(_ queue: [Result<SideQuestion.Reply, SecondOpinion.Failure>]) { self.queue = queue }

    func next() -> Result<SideQuestion.Reply, SecondOpinion.Failure> {
        lock.withLock { queue.isEmpty ? .failure(.init(message: "No reply")) : queue.removeFirst() }
    }
}
