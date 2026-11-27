import Foundation
import Testing
@testable import MenuBarApp

// The Lineup shows the reviewers a second opinion would go to, and once asked, what each
// of them is doing, in words as well as marks.
@MainActor
struct SecondOpinionLineupTests {

    private func run(_ agent: AgentKind, _ state: SecondOpinionRun.State, activity: String = "Gathering the changes") -> SecondOpinionRun {
        var run = SecondOpinionRun(reviewer: SecondOpinion.Reviewer(agent: agent), started: Date(timeIntervalSince1970: 100),
                                   request: SecondOpinionRequest(repositories: [], executable: "/bin/true"))
        run.state = state
        run.activity = activity
        return run
    }

    @Test func theLineupIsEveryInstalledAgentButTheAuthor() {
        #expect(SecondOpinionLineup.reviewers(installed: [.claudeCode, .codex, .copilot], author: .claudeCode) == [.codex, .copilot])
        #expect(SecondOpinionLineup.reviewers(installed: [.claudeCode], author: .claudeCode).isEmpty)
    }

    @Test func withNobodyToAskItSaysWhatToInstall() {
        #expect(SecondOpinionLineup.installHint(author: .claudeCode) == "Install Codex, Copilot or Kiro to ask for a second opinion")
    }

    @Test func onceAskedTheTilesAreWhoeverWasAsked() {
        let runs = [run(.codex, .running), run(.codex, .running)]
        let status = SecondOpinionStatus(runs: runs, findings: [], dismissed: 0)
        #expect(SecondOpinionLineup.agents(lineup: [.codex, .copilot], runs: runs, status: status) == [.codex])
        #expect(SecondOpinionLineup.agents(lineup: [.codex, .copilot], runs: [], status: .ask) == [.codex, .copilot])
    }

    @Test func eachReviewerWearsWhatItIsDoing() {
        let runs = [run(.codex, .finished(found: 0)), run(.copilot, .running), run(.claudeCode, .failed("Not signed in"))]
        let status = SecondOpinionStatus(runs: runs, findings: [], dismissed: 0)
        #expect(SecondOpinionLineup.marks(runs: runs, status: status)
                == [.codex: .done, .copilot: .working, .claudeCode: .failed])
    }

    @Test func anAgentOnTwoSeatsShowsItIsStillWorkingUntilBothAreDone() {
        let runs = [run(.codex, .finished(found: 0)), run(.codex, .running)]
        let status = SecondOpinionStatus(runs: runs, findings: [], dismissed: 0)
        #expect(SecondOpinionLineup.marks(runs: runs, status: status) == [.codex: .working])
    }

    @Test func findingsTurnTheirReviewersAmberAndNothingElse() {
        #expect(SecondOpinionLineup.marks(runs: [], status: .ready(agents: [.copilot], pending: 2)) == [.copilot: .findings])
        #expect(SecondOpinionLineup.marks(runs: [], status: .ask).isEmpty)
    }

    @Test func theWordsSayWhoIsStillReading() {
        #expect(SecondOpinionLineup.readingWords(runs: [run(.codex, .running, activity: "Reading Store.swift")])
                == "Reading Store.swift")
        #expect(SecondOpinionLineup.readingWords(runs: [run(.codex, .finished(found: 1)), run(.copilot, .running)])
                == "Copilot is still reading")
        #expect(SecondOpinionLineup.readingWords(runs: [run(.codex, .running), run(.copilot, .running)])
                == "Codex and Copilot are reading")
    }

    @Test func progressCountsReviewersDoneOutOfThoseAsked() {
        #expect(SecondOpinionLineup.progress(runs: [run(.codex, .running)]) == nil)
        #expect(SecondOpinionLineup.progress(runs: [run(.codex, .finished(found: 0)), run(.copilot, .running)]) == 0.5)
    }

    @Test func aSortedRoundCountsWhatWasKept() {
        #expect(SecondOpinionLineup.settledWords(kept: 2, dismissed: 1) == "2 kept, 1 dismissed")
        #expect(SecondOpinionLineup.settledWords(kept: 0, dismissed: 0) == "Nothing to raise")
    }
}
