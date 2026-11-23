import AppKit
import SwiftUI

extension ChangesView {
    // MARK: Second opinion

    // The header's control opens the findings once there are some. While the reviewers
    // read, it opens their lanes in a panel of its own instead.
    private func openSecondOpinion(_ review: ReviewTarget) {
        switch SecondOpinionStatus(reviews: review.reviews, sessionID: review.sessionID) {
        case .ready: openFindings(review)
        case .settled(let kept, let dismissed) where kept + dismissed > 0: openFindings(review)
        case .ask, .reviewing, .failed, .settled: break
        }
    }

    func takeSecondOpinionRequest() {
        guard let request = navigation.secondOpinionRequest else { return }
        navigation.secondOpinionRequest = nil
        guard let review else { return }
        mode = .changes
        switch request {
        case .ask(let lineup): askForSecondOpinion(review, lineup: lineup)
        case .open: openSecondOpinion(review)
        }
    }

    // Opens on the first finding still to look at, from one reviewer when asked.
    func openFindings(_ review: ReviewTarget, from reviewer: SecondOpinion.Reviewer? = nil) {
        let list = SecondOpinionFindings.ordered(review.reviews.findings(review.sessionID))
        let first = list.first { $0.isPending && (reviewer == nil || $0.raised(by: reviewer!)) }
            ?? list.first { reviewer == nil || $0.raised(by: reviewer!) }
        let dialog = Dialog(
            title: "Findings",
            content: AnyView(SecondOpinionFindingsView(review: review, selected: first?.id)),
            actions: [], width: 900, framesItself: true)
        secondOpinionDialog = dialog.id
        dialogs.show(dialog)
    }

    private func askForSecondOpinion(_ review: ReviewTarget, lineup: [SecondOpinion.Reviewer]) {
        let scope: SecondOpinionRequest.Scope
        switch navigation.secondOpinionScope {
        case .all: scope = .all
        case .file: scope = selected.map { .file(root: repoRoot, path: $0.path, base: comparedBases[root]) } ?? .all
        case .sinceReview: scope = review.reviews.latestTrees(review.sessionID).map { .sinceReview(trees: $0) } ?? .all
        case .branch: scope = comparedBases.isEmpty ? .all : .branch(bases: comparedBases)
        }
        let running = Set(review.reviews.runs(review.sessionID).filter(\.isRunning).map(\.reviewer))
        var seen = Set<SecondOpinion.Reviewer>()
        let chosen = lineup.filter { !running.contains($0) && seen.insert($0).inserted }
        review.reviews.beginSecondOpinion(review.sessionID)
        startSecondOpinion(review, reviewers: chosen, scope: scope)
    }

    private func startSecondOpinion(_ review: ReviewTarget, reviewers: [SecondOpinion.Reviewer],
                                    scope: SecondOpinionRequest.Scope) {
        var asked: [String] = []
        for reviewer in reviewers {
            guard let executable = review.executable(reviewer.agent) else { continue }
            review.reviews.startSecondOpinion(review.sessionID, reviewer: reviewer, request: SecondOpinionRequest(
                focus: SecondOpinion.Focus.allCases.filter(navigation.secondOpinionFocus.contains),
                note: navigation.secondOpinionNote, scope: scope, repositories: reviewRepositories, executable: executable,
                servers: navigation.secondOpinionServers))
            asked.append(reviewer.label())
        }
        guard !asked.isEmpty else { return }
        announce("Asked \(asked.joined(separator: " and ")) for a second opinion")
    }

    // The base each project is compared with on this screen, for the ones that show one.
    private var comparedBases: [String: String] {
        var bases: [String: String] = [:]
        for repository in repositories {
            guard let snapshot = navigation.snapshots[repository.root], snapshot.comparedToRemote,
                  let base = snapshot.remoteBase else { continue }
            bases[repository.root] = base.ref
        }
        return bases
    }

    // The open project leads, so the reviewer starts in the folder the session works in.
    var reviewRepositories: [ReviewRepository] {
        let open = repositories.filter { $0.root == root } + repositories.filter { $0.root != root }
        return open.map { ReviewRepository(root: $0.root, name: $0.name) }
    }

    // Says once when each reviewer is done, with the way to its findings. The progress and
    // findings dialogs already show it happen, so nothing is said while one is open.
    func reportFinishedRuns(old: [SecondOpinionRun], new: [SecondOpinionRun]) {
        guard let review else { return }
        for run in new where !run.isRunning {
            guard old.first(where: { $0.reviewer == run.reviewer })?.isRunning == true else { continue }
            if secondOpinionDialog != nil, dialogs.current?.id == secondOpinionDialog {
                announce("\(run.reviewer.label()) finished its review")
                continue
            }
            switch run.state {
            case .finished(let found) where found > 0:
                showToast("\(run.reviewer.label()) found \(counted(found, "thing")) to look at", action: "Look at them") {
                    openFindings(review, from: run.reviewer)
                }
            case .finished:
                showToast("\(run.reviewer.label()) found nothing worth raising")
            case .failed:
                showToast("\(run.reviewer.label()) could not finish the review", action: "Try again") {
                    review.reviews.retrySecondOpinion(review.sessionID, reviewer: run.reviewer)
                }
            case .running:
                break
            }
        }
    }
}
