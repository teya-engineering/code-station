import Testing
@testable import MenuBarApp

@MainActor
struct CommitDialogTests {
    private let files = [
        GitChange(path: "src/a.swift", kind: .modified, isStaged: false, isUnstaged: true, added: 3, removed: 1, isBinary: false),
        GitChange(path: "docs/b.md", kind: .added, isStaged: false, isUnstaged: true, added: 24, removed: 0, isBinary: false)
    ]

    private func model(draft: ChangesCommitDraft = ChangesCommitDraft(), files: [GitChange]? = nil,
                       canAmend: Bool = true, result: String? = nil,
                       record: @escaping (String, Bool) -> Void = { _, _ in }) -> CommitDialogModel {
        CommitDialogModel(draft: draft, files: files ?? self.files, canAmend: canAmend,
                          lastSubject: "Remove gallery button") { message, _, amend in
            record(message, amend)
            return result
        }
    }

    @Test func titlesFollowTheFilesAndTheAmendChoice() {
        let dialog = model()
        #expect(dialog.title == "Commit changes")
        #expect(dialog.actionTitle == "Commit 2 files")
        #expect(dialog.includedLabel == "2 files included")
        #expect(dialog.added == 27)
        #expect(dialog.removed == 1)
        dialog.amend = true
        #expect(dialog.title == "Amend last commit")
        #expect(dialog.actionTitle == "Amend commit")
        #expect(dialog.includedLabel == "Adds 2 files")
    }

    @Test func amendingFillsTheLastSubjectAndUntickingBringsTheDraftBack() {
        let dialog = model()
        dialog.message = "My own words"
        dialog.amend = true
        #expect(dialog.message == "Remove gallery button")
        dialog.amend = false
        #expect(dialog.message == "My own words")
    }

    @Test func aDraftLeftInAmendModeIsResetWhenAmendingIsNotAllowed() {
        let draft = ChangesCommitDraft()
        draft.message = "Mine"
        draft.setAmend(true, lastMessage: "Old")
        let dialog = model(draft: draft, canAmend: false)
        #expect(!dialog.amend)
        #expect(dialog.message == "Mine")
    }

    @Test func theCounterMeasuresOnlyTheSummaryLine() {
        let dialog = model()
        dialog.message = "Short summary\n\n" + String(repeating: "x", count: 200)
        #expect(dialog.summaryLength == 13)
        #expect(!dialog.summaryTooLong)
        dialog.message = String(repeating: "y", count: 73)
        #expect(dialog.summaryTooLong)
    }

    @Test func aBlankMessageOrAConflictBlocksTheCommit() {
        #expect(!model().canCommit)
        let dialog = model()
        dialog.message = "  \n "
        #expect(!dialog.canCommit)
        dialog.message = "Fix it"
        #expect(dialog.canCommit)
        let conflicted = model(files: [GitChange(path: "a", kind: .conflicted, isStaged: false,
                                                 isUnstaged: true, isBinary: false)])
        conflicted.message = "Fix it"
        #expect(!conflicted.canCommit)
    }

    @Test func aFailedCommitKeepsTheMessageAndShowsTheError() async {
        let draft = ChangesCommitDraft()
        let dialog = model(draft: draft, result: "pre-commit hook failed")
        dialog.message = "Keep me"
        #expect(await dialog.commit() == false)
        #expect(dialog.error == "pre-commit hook failed")
        #expect(draft.message == "Keep me")
        #expect(!dialog.isCommitting)
    }

    @Test func aSuccessfulCommitSendsTheTrimmedMessageAndClearsTheDraft() async {
        let draft = ChangesCommitDraft()
        var sent: (String, Bool)?
        let dialog = model(draft: draft) { sent = ($0, $1) }
        dialog.message = "  Ship it \n"
        #expect(await dialog.commit())
        #expect(sent?.0 == "Ship it")
        #expect(sent?.1 == false)
        #expect(draft.message.isEmpty)
        #expect(dialog.error == nil)
    }
}
