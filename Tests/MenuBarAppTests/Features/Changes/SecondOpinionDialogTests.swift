import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// The second opinion's control in the review bar says where things stand, and its
// findings dialog goes through what came back in a fixed order and remembers what was
// dismissed until the next ask.
@MainActor
struct SecondOpinionDialogTests {

    private func finding(_ agent: AgentKind, path: String = "App.swift", line: Int = 1,
                         severity: ReviewComment.Severity? = .should, body: String = "Fix this") -> ReviewComment {
        ReviewComment(root: "/repo", path: path, anchor: DiffAnchor(side: .new, line: line),
                      excerpt: "x", body: body, author: .agent(agent), status: .pending, severity: severity)
    }

    private func run(_ agent: AgentKind, _ state: SecondOpinionRun.State) -> SecondOpinionRun {
        var run = SecondOpinionRun(reviewer: SecondOpinion.Reviewer(agent: agent), started: Date(timeIntervalSince1970: 100),
                                   request: SecondOpinionRequest(repositories: [], executable: "/bin/true"))
        run.state = state
        return run
    }

    @Test func theControlAsksWhenNothingHasBeenAsked() {
        #expect(SecondOpinionStatus(runs: [], findings: [], dismissed: 0) == .ask)
    }

    @Test func theControlSaysWhoIsReviewingAndWhatHasComeBackSoFar() {
        let status = SecondOpinionStatus(runs: [run(.codex, .running), run(.claudeCode, .finished(found: 1))],
                                         findings: [finding(.claudeCode)], dismissed: 0)
        #expect(status == .reviewing(agents: [.codex], started: Date(timeIntervalSince1970: 100), pending: 1))
    }

    @Test func findingsToLookAtOutrankAFailedReviewer() {
        let failed = run(.codex, .failed("Not signed in"))
        #expect(SecondOpinionStatus(runs: [failed], findings: [], dismissed: 0) == .failed(.codex))
        let status = SecondOpinionStatus(runs: [failed, run(.copilot, .finished(found: 1))],
                                         findings: [finding(.copilot)], dismissed: 0)
        #expect(status == .ready(agents: [.copilot], pending: 1))
    }

    @Test func onceEverythingIsDecidedTheControlCountsKeptAndDismissed() {
        var kept = finding(.codex)
        kept.status = .kept
        let status = SecondOpinionStatus(runs: [run(.codex, .finished(found: 3))], findings: [kept], dismissed: 2)
        #expect(status == .settled(kept: 1, dismissed: 2))
    }

    @Test func findingsAreGroupedByFileWithTheMostSeriousFirst() {
        let look = finding(.codex, path: "docs/plugins.md", line: 30, severity: .look)
        let shouldLate = finding(.codex, path: "Store.swift", line: 142)
        let shouldEarly = finding(.claudeCode, path: "Store.swift", line: 88)
        let must = finding(.codex, path: "Installer.swift", line: 23, severity: .must)
        let ordered = SecondOpinionFindings.ordered([look, shouldLate, shouldEarly, must])
        #expect(ordered.map(\.id) == [must.id, shouldEarly.id, shouldLate.id, look.id])
    }

    @Test func decidingMovesOnToTheNextUndecidedGoingRound() {
        let list = [finding(.codex, line: 1), finding(.codex, line: 2), finding(.codex, line: 3)]
        let open: Set<UUID> = [list[0].id, list[2].id]
        #expect(SecondOpinionFindings.next(after: list[0].id, in: list) { open.contains($0.id) } == list[2].id)
        #expect(SecondOpinionFindings.next(after: list[2].id, in: list) { open.contains($0.id) } == list[0].id)
        #expect(SecondOpinionFindings.next(after: nil, in: list) { open.contains($0.id) } == list[0].id)
        #expect(SecondOpinionFindings.next(after: list[1].id, in: list) { _ in false } == nil)
    }

    @Test func aDismissedFindingStaysVisibleUntilTheNextAsk() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let first = finding(.codex, line: 1)
        let second = finding(.codex, line: 2)
        store.addFindings([first, second], from: .codex, to: session)
        store.dismiss(first.id, from: session)
        #expect(store.dismissedFindings(session).map(\.id) == [first.id])
        #expect(Set(store.findings(session).map(\.id)) == [first.id, second.id])

        store.restore(store.dismissedFindings(session)[0], to: session)
        #expect(store.dismissedFindings(session).isEmpty)
        #expect(store.pending(session).count == 2)

        store.dismissAllPending(session)
        #expect(store.dismissedFindings(session).count == 2)
        store.beginSecondOpinion(session)
        #expect(store.dismissedFindings(session).isEmpty)
    }

    @Test func deletingYourOwnCommentIsNotADismissedFinding() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let mine = ReviewComment(root: "/repo", path: "App.swift", anchor: DiffAnchor(side: .new, line: 1),
                                 excerpt: "x", body: "Mine")
        store.add(mine, to: session)
        store.dismiss(mine.id, from: session)
        #expect(store.dismissedFindings(session).isEmpty)
    }

    @Test func aKeptFindingCanGoBackToBeLookedAt() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let one = finding(.codex)
        store.addFindings([one], from: .codex, to: session)
        store.keep(one.id, in: session)
        store.reopen(one.id, in: session)
        #expect(store.pending(session).map(\.id) == [one.id])
    }

    @Test func aFreshAskClearsFinishedLanesButNotOnesAtWork() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let request = SecondOpinionRequest(repositories: [ReviewRepository(root: scratch.path, name: "App")],
                                           executable: "/usr/bin/false")
        store.startSecondOpinion(session, reviewer: SecondOpinion.Reviewer(agent: .copilot), request: request)
        store.beginSecondOpinion(session)
        #expect(store.isReviewing(session, reviewer: SecondOpinion.Reviewer(agent: .copilot)))
        #expect(await waitUntil { store.runs(session).first?.isRunning == false })

        store.beginSecondOpinion(session)
        #expect(store.runs(session).isEmpty)
    }

    @Test func theCodeAroundAFindingIsReadFromItsFile() {
        let one = finding(.codex, line: 3)
        let file = "one\ntwo\nthree\nfour\nfive\nsix"
        let lines = SecondOpinionFindingsView.context(for: one) { _ in file }
        #expect(lines.map(\.number) == [1, 2, 3, 4])
        #expect(lines.map(\.text) == ["one", "two", "three", "four"])
        let missing = SecondOpinionFindingsView.context(for: one) { _ in nil }
        #expect(missing.map(\.text) == ["x"])
    }
}
