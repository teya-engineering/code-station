import Foundation
import Testing
@testable import MenuBarApp

// What a second opinion asked from a session is about, and where its request goes.
@MainActor
struct SessionSecondOpinionTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let runner: SessionRunner
    private let gitStats = GitStatsCache()
    private var session: ChatSession

    private let asked = ChatMessage(role: .user, text: "Retry timed-out calls.")
    private let answer = ChatMessage(role: .assistant, text: "Retries are in.")
    private let followUp = ChatMessage(role: .user, text: "And back off?")
    private let latest = ChatMessage(role: .assistant, text: "Backing off now.")

    init() throws {
        (store, scratch) = TestStore.make()
        runner = SessionRunner(store: store, preferences: testPreferences.store, paths: [:])
        session = ChatSession(projectID: UUID())
        session.messages = [asked, answer, followUp, latest]
    }

    @Test func anAnswerIsJudgedAgainstThePromptBeforeIt() {
        let subject = SessionSecondOpinion.answerSubject(answer, in: session)
        #expect(subject.kind == .answer)
        #expect(subject.id == "answer:" + answer.id.uuidString)
        #expect(subject.text == "Retries are in.")
        #expect(subject.request == "Retry timed-out calls.")
    }

    @Test func supportingConversationExcludesTheSubjectItsRequestAndLaterTurns() {
        let picked = SessionSecondOpinion.answerSubject(answer, in: session)
        #expect(SessionSecondOpinion.earlierConversation(for: picked, in: session).isEmpty)
        let last = SessionSecondOpinion.answerSubject(latest, in: session)
        #expect(SessionSecondOpinion.earlierConversation(for: last, in: session)
                == "User: Retry timed-out calls.\n\nAgent: Retries are in.")
    }

    @Test func theAnswerStillBeingWrittenCannotBeJudged() {
        #expect(SessionSecondOpinion.canJudge(latest, in: session, state: .idle))
        #expect(!SessionSecondOpinion.canJudge(latest, in: session, state: .streaming))
        #expect(SessionSecondOpinion.canJudge(answer, in: session, state: .streaming))
        #expect(!SessionSecondOpinion.canJudge(asked, in: session, state: .idle))
        #expect(SessionSecondOpinion.latestAnswer(in: session, state: .idle)?.id == latest.id)
        #expect(SessionSecondOpinion.latestAnswer(in: session, state: .streaming)?.id == answer.id)
    }

    @Test func theWholeConversationIsJudgedAgainstEverythingAsked() throws {
        let subject = try #require(SessionSecondOpinion.conversationSubject(session, state: .idle))
        #expect(subject.kind == .conversation)
        #expect(subject.id == "conversation:" + latest.id.uuidString)
        #expect(subject.request == "Retry timed-out calls.\n\nAnd back off?")

        var empty = session
        empty.messages = [asked]
        #expect(SessionSecondOpinion.conversationSubject(empty, state: .idle) == nil)
    }

    @Test func wholeChatKeepsEveryTurnEvenBeyondTheSideQuestionBudget() throws {
        var session = session
        session.messages.insert(ChatMessage(role: .assistant, text: String(repeating: "Context. ", count: 6000)), at: 2)
        let subject = try #require(SessionSecondOpinion.conversationSubject(session, state: .idle))
        #expect(subject.text.hasPrefix("User: Retry timed-out calls."))
        #expect(subject.text.contains(String(repeating: "Context. ", count: 5999)))
        #expect(subject.text.hasSuffix("Agent: Backing off now."))
    }

    @Test func theHeaderOpensOnTheLatestAnswerAndMarksIt() {
        let opinion = SessionSecondOpinion()
        opinion.lanesOpen = true
        opinion.anchor = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(opinion.open(session, on: nil, anchor: nil,
                             screen: .init(), runner: runner, gitStats: gitStats))

        #expect(opinion.ask?.stop == .answer)
        #expect(opinion.ask?.facts.origin == .header)
        #expect(opinion.ask?.chatSubject?.id == "answer:" + latest.id.uuidString)
        #expect(opinion.ask?.chatAnchor == latest.id)
        // The header keeps its own place, so a press recorded elsewhere is dropped.
        #expect(opinion.ask?.anchor == nil)
        #expect(opinion.anchor == nil)
        #expect(!opinion.lanesOpen)
        #expect(opinion.railShows(latest))
        #expect(!opinion.railShows(answer))

        opinion.close()
        #expect(opinion.ask == nil)
        #expect(!opinion.railShows(latest))
    }

    @Test func aPickedAnswerOpensWhereItWasPressed() {
        let opinion = SessionSecondOpinion()
        let pressed = CGRect(x: 10, y: 20, width: 30, height: 40)
        opinion.anchor = pressed
        #expect(opinion.open(session, on: SessionSecondOpinion.answerSubject(answer, in: session),
                             anchor: answer.id,
                             screen: .init(), runner: runner, gitStats: gitStats))

        #expect(opinion.ask?.facts.origin == .answer)
        #expect(opinion.ask?.facts.answer?.picked == true)
        #expect(opinion.ask?.anchor == pressed)
        #expect(opinion.ask?.chatAnchor == answer.id)
        #expect(opinion.railShows(answer))
    }

    @Test func aSessionWithNothingToJudgeOpensNoCard() {
        var empty = session
        empty.messages = []
        let opinion = SessionSecondOpinion()
        #expect(!opinion.open(empty, on: nil, anchor: nil,
                              screen: .init(), runner: runner, gitStats: gitStats))
        #expect(opinion.ask == nil)
    }

    @Test func aReviewOfTheChangesIsLeftForTheChangesScreenToStart() throws {
        let opinion = SessionSecondOpinion()
        #expect(opinion.open(session, on: nil, anchor: nil,
                             screen: .init(), runner: runner, gitStats: gitStats))
        let ask = try #require(opinion.ask)
        let lineup = [SecondOpinion.Reviewer(agent: .codex)]
        let choice = SecondOpinionAskChoice(stop: .sinceReview, lineup: lineup, chatFocus: [],
                                            chatReading: .init(), changesFocus: [.bugs],
                                            designFocus: [], designReading: .init(), note: "Mind the retries",
                                            scope: .sinceReview(trees: ["/repo": "review-tree"]))
        let navigation = ChangesNavigationMemory()

        #expect(SessionSecondOpinion.start(choice, ask: ask, session: session, design: nil,
                                           installed: [], navigation: navigation, runner: runner))

        #expect(navigation.secondOpinionRequest == .ask(lineup))
        #expect(navigation.secondOpinionScope == .sinceReview)
        #expect(navigation.secondOpinionFocus == [.bugs])
        #expect(navigation.secondOpinionNote == "Mind the retries")
        #expect(navigation.secondOpinionServers == nil)
        #expect(navigation.secondOpinionChoice?.scope == .sinceReview(trees: ["/repo": "review-tree"]))
        #expect(navigation.compareRefs.isEmpty)
        #expect(navigation.lastCommitCompares.isEmpty)
    }

    @Test func aDesignReviewWithoutADesignStartsNothing() throws {
        let opinion = SessionSecondOpinion()
        #expect(opinion.open(session, on: nil, anchor: nil,
                             screen: .init(), runner: runner, gitStats: gitStats))
        let choice = SecondOpinionAskChoice(stop: .design, lineup: [], chatFocus: [], chatReading: .init(),
                                            changesFocus: [], designFocus: [], designReading: .init(), note: "")
        #expect(!SessionSecondOpinion.start(choice, ask: try #require(opinion.ask), session: session,
                                            design: nil, installed: [],
                                            navigation: ChangesNavigationMemory(), runner: runner))
    }
}
