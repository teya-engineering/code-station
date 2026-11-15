import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

struct SecondOpinionAskTests {
    private let answer = ChatSecondOpinion.Subject(kind: .answer, id: "answer:1", text: "Retries now back off.",
                                                   request: "Add retries.")
    private let plan = ChatSecondOpinion.Subject(kind: .plan, id: "plan:1", text: "1. Retry.", request: "Plan it.")
    private let retry = SecondOpinionAskFacts.File(root: "/repo", path: "retry/RetryPolicy.java", added: 18, removed: 9)
    private let test = SecondOpinionAskFacts.File(root: "/repo", path: "retry/RetryPolicyTest.java", added: 23, removed: 0)
    private let turns: [SecondOpinionAskFacts.Turn] = [
        .init(fromPerson: true, text: "Add retries."), .init(fromPerson: false, text: "Done."),
        .init(fromPerson: true, text: "Add jitter."), .init(fromPerson: false, text: "Done too.")
    ]

    private func facts(_ origin: SecondOpinionOrigin = .header, answer: ChatSecondOpinion.Subject? = nil,
                       picked: Bool = false, files: [SecondOpinionAskFacts.File] = [],
                       file: SecondOpinionAskFacts.File? = nil, canReadSince: Bool = false,
                       design: [String]? = nil, turns: [SecondOpinionAskFacts.Turn] = [],
                       showsDesign: Bool = false) -> SecondOpinionAskFacts {
        SecondOpinionAskFacts(origin: origin, answer: answer.map { .init(subject: $0, picked: picked) },
                              files: files, file: file, canReadSince: canReadSince, designScreens: design,
                              turns: turns, showsDesign: showsDesign)
    }

    @Test func onlyStopsWithSomethingBehindThemShowNarrowestFirst() {
        #expect(SecondOpinionAsk.stops(facts()) == [])
        #expect(SecondOpinionAsk.stops(facts(answer: answer, turns: Array(turns.prefix(2)))) == [.answer])
        #expect(SecondOpinionAsk.stops(facts(answer: answer, files: [retry, test], file: retry, canReadSince: true,
                                             design: ["Home"], turns: turns))
                == [.file, .answer, .sinceReview, .uncommitted, .design, .conversation])
        // Since the last review needs both a review and something changed.
        #expect(!SecondOpinionAsk.stops(facts(canReadSince: true)).contains(.sinceReview))
    }

    @Test func eachWayInProposesItsOwnSubject() {
        let everything = facts(answer: answer, files: [retry, test], file: retry, design: ["Home"], turns: turns)
        #expect(SecondOpinionAsk.initialStop(everything) == .uncommitted)

        var fromAnswer = everything
        fromAnswer.origin = .answer
        #expect(SecondOpinionAsk.initialStop(fromAnswer) == .answer)

        var fromFile = everything
        fromFile.origin = .file
        #expect(SecondOpinionAsk.initialStop(fromFile) == .file)

        var onDesign = everything
        onDesign.showsDesign = true
        #expect(SecondOpinionAsk.initialStop(onDesign) == .design)

        // A plan waiting on an answer comes before everything else.
        var waiting = onDesign
        waiting.answer = .init(subject: plan, picked: false)
        #expect(SecondOpinionAsk.initialStop(waiting) == .answer)

        // Nothing changed yet, so the header asks about the last answer.
        #expect(SecondOpinionAsk.initialStop(facts(answer: answer, turns: turns)) == .answer)
        #expect(SecondOpinionAsk.initialStop(facts()) == nil)
    }

    @Test func theWordsFollowWhatIsPicked() {
        let picked = facts(.answer, answer: answer, picked: true)
        #expect(SecondOpinionAsk.stopTitle(.answer, facts: picked) == "This answer")
        #expect(SecondOpinionAsk.title(.answer, facts: facts(answer: answer)) == "The last answer")
        #expect(SecondOpinionAsk.title(.answer, facts: facts(answer: plan)) == "This plan")
        #expect(SecondOpinionAsk.title(.file, facts: facts(files: [retry], file: retry)) == "RetryPolicy.java")
        #expect(SecondOpinionAsk.fact(.uncommitted, facts: facts(files: [retry, test])) == "2 files")
        #expect(SecondOpinionAsk.fact(.conversation, facts: facts(turns: turns)) == "2 turns, checked against what you asked")
    }

    @Test func theTooltipSaysTheSentenceAClickProposes() {
        let changed = facts(answer: answer, files: [retry])
        #expect(SecondOpinionAsk.proposal(.uncommitted, facts: changed, reviewers: [.codex])
                == "Codex reviews the uncommitted changes")
        #expect(SecondOpinionAsk.proposal(.answer, facts: changed, reviewers: [.codex, .copilot])
                == "Codex and Copilot review the last answer")
        #expect(SecondOpinionAsk.proposal(nil, facts: changed, reviewers: [.codex]) == "Nothing to review yet")
    }

    @Test func thePreviewLightsOnlyTheFilesInScope() {
        let changed = facts(files: [retry, test], file: test)
        #expect(SecondOpinionAsk.litFiles(.uncommitted, facts: changed, sinceReview: nil) == [retry.id, test.id])
        #expect(SecondOpinionAsk.litFiles(.file, facts: changed, sinceReview: nil) == [test.id])
        #expect(SecondOpinionAsk.litFiles(.sinceReview, facts: changed, sinceReview: [retry.id]) == [retry.id])
        #expect(SecondOpinionAsk.litFiles(.answer, facts: changed, sinceReview: nil) == nil)
    }

    @Test func theAskButtonNamesWhoIsAskedOrWhatIsMissing() {
        let codex = SecondOpinion.Reviewer(agent: .codex)
        let copilot = SecondOpinion.Reviewer(agent: .copilot)
        let codexMini = SecondOpinion.Reviewer(agent: .codex, model: "mini")
        #expect(SecondOpinionAsk.askTitle(lineup: [], hasFocus: true) == "Pick a reviewer")
        #expect(SecondOpinionAsk.askTitle(lineup: [codex], hasFocus: false) == "Pick what to look for")
        #expect(SecondOpinionAsk.askTitle(lineup: [codex, codex], hasFocus: true) == "Ask Codex")
        #expect(SecondOpinionAsk.askTitle(lineup: [codex, copilot], hasFocus: true) == "Ask Codex and Copilot")
        #expect(SecondOpinionAsk.askTitle(lineup: [codex, codexMini], hasFocus: true) == "Ask 2 reviewers")
        #expect(SecondOpinionAsk.estimate(lineup: []) == "Nobody is picked to ask.")
        #expect(SecondOpinionAsk.estimate(lineup: [SecondOpinion.Reviewer(agent: .codex, effort: "low"),
                                                  SecondOpinion.Reviewer(agent: .copilot, effort: "xhigh")])
                == "About 6 min. You can keep working.")
    }

    @Test func wordsTheyWriteJoinWhatTheyTicked() {
        #expect(SecondOpinion.lookFor(["bugs"], note: "  the retry cap  ", standard: ["x"])
                == "bugs; and this, in the person's own words: the retry cap")
        #expect(SecondOpinion.lookFor([], note: "the retry cap", standard: ["x"])
                == "and this, in the person's own words: the retry cap")
        #expect(SecondOpinion.lookFor([], note: " ", standard: ["bugs", "risks"]) == "bugs; risks")
        let changes = SecondOpinion.prompt(for: [], focus: [.security], note: "the claim query")
        #expect(changes.contains("security issues; and this, in the person's own words: the claim query"))
    }

    @Test func theWholeConversationIsJudgedAsAConversation() {
        let conversation = ChatSecondOpinion.Subject(kind: .conversation, id: "conversation:1",
                                                     text: "User: Add retries.\n\nAgent: Done.",
                                                     request: "Add retries.")
        let prompt = ChatSecondOpinion.prompt(for: .init(subject: conversation, note: "idempotency",
                                                         reading: .init(files: true, conversation: true),
                                                         conversation: "User: never sent twice",
                                                         directories: ["/repo"], executable: "/bin/codex"))
        #expect(prompt.hasPrefix("Another coding agent had the conversation below with a person."))
        #expect(prompt.contains("in the person's own words: idempotency"))
        #expect(prompt.contains("The conversation:\nUser: Add retries."))
        // The conversation is the subject itself, so it is not sent a second time.
        #expect(!prompt.contains("never sent twice"))
        #expect(conversation.name == "the whole conversation")
        #expect(ChatSecondOpinion.feedback([], subject: conversation, names: "Codex")
                .hasPrefix("Codex looked at our conversation so far."))
    }
}

// The card keeps one size while the knob moves, so it never jumps under the pointer, and
// it keeps to its content whatever room it is offered.
@MainActor
struct SecondOpinionAskCardLayoutTests {
    private let testPreferences = TestPreferences()

    @Test func theCardKeepsItsHeightAsTheSubjectChanges() {
        let answer = ChatSecondOpinion.Subject(kind: .answer, id: "answer:1",
                                               text: String(repeating: "A long answer. ", count: 60), request: "Ask.")
        let files = (0..<12).map { SecondOpinionAskFacts.File(root: "/repo", path: "src/File\($0).swift",
                                                              added: $0 * 7, removed: $0) }
        let facts = SecondOpinionAskFacts(origin: .header, answer: .init(subject: answer, picked: false),
                                          files: files, file: files[3], designScreens: ["Home", "Settings"],
                                          turns: (0..<8).map { .init(fromPerson: $0 % 2 == 0, text: "Turn \($0)") })
        var heights: [SecondOpinionStop: CGFloat] = [:]
        for stop in SecondOpinionAsk.stops(facts) {
            var height: CGFloat = 0
            let card = SecondOpinionAskCard(
                facts: facts, stop: .constant(stop), author: SecondOpinion.Reviewer(agent: .claudeCode),
                installed: [.codex, .copilot, .claudeCode], lineup: [SecondOpinion.Reviewer(agent: .codex)],
                changesFocus: Set(SecondOpinion.Focus.standard), ask: { _ in }, close: {})
            let root = ZStack {
                card.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(width: 1400, height: 1200)
            .environment(DialogPresenter())
            .environment(SessionRunner(preferences: testPreferences.store, paths: [:]))
            .environment(TooltipPresenter())
            .environment(MenuPresenter())

            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 1400, height: 1200)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            heights[stop] = height
        }
        #expect(heights.count == 5)
        #expect(Set(heights.values).count == 1)
        #expect((heights.values.first ?? 0) > 200)
        #expect((heights.values.first ?? 0) < 480)
    }
}
