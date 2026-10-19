import AppKit
import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// Comments left on a session's diff hang from numbered lines, follow the code when the
// agent moves it, and go back to the agent as one prompt that quotes what they are about.
@MainActor
struct ReviewCommentTests {

    private var lines: [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -10,4 +10,5 @@"),
         DiffLine(id: 1, kind: .context, text: " let items = load()"),
         DiffLine(id: 2, kind: .deletion, text: "-let first = items[0]"),
         DiffLine(id: 3, kind: .addition, text: "+let first = items.first!"),
         DiffLine(id: 4, kind: .addition, text: "+print(first)"),
         DiffLine(id: 5, kind: .context, text: " return first")]
    }

    private func comment(_ side: ReviewSide, _ line: Int, excerpt: String, body: String = "Fix this",
                         lastLine: Int? = nil) -> ReviewComment {
        ReviewComment(root: "/repo", path: "App.swift",
                      anchor: DiffAnchor(side: side, line: line, lastLine: lastLine),
                      excerpt: excerpt, body: body)
    }

    @Test func linesAreNumberedInTheVersionTheyBelongTo() {
        let numbered = NumberedDiffLine.lines(lines)
        #expect(numbered.map(\.side) == [.old, .new, .old, .new, .new, .old, .new])
        #expect(numbered.map(\.number) == [10, 10, 11, 11, 12, 12, 13])
        #expect(numbered[2].code == "let first = items[0]")
    }

    @Test func aCommentSitsUnderTheLineItWasLeftOn() {
        let placement = ReviewPlacement.place([comment(.new, 11, excerpt: "let first = items.first!")], in: lines)
        #expect(placement.below[3]?.count == 1)
        #expect(placement.unplaced.isEmpty)
    }

    @Test func aRemovedLineIsFoundOnTheOldSide() {
        let placement = ReviewPlacement.place([comment(.old, 11, excerpt: "let first = items[0]")], in: lines)
        #expect(placement.below[2]?.count == 1)
    }

    @Test func aCommentFollowsItsCodeWhenTheLinesMove() {
        // Left on line 11 before two lines were added above it.
        let placement = ReviewPlacement.place([comment(.new, 9, excerpt: "print(first)")], in: lines)
        #expect(placement.below[4]?.count == 1)
    }

    @Test func aCommentWhoseCodeIsGoneIsListedApart() {
        let placement = ReviewPlacement.place([comment(.new, 11, excerpt: "something else entirely")], in: lines)
        #expect(placement.below.isEmpty)
        #expect(placement.unplaced.count == 1)
    }

    @Test func aRangeIsDrawnUnderItsLastLine() {
        let range = comment(.new, 11, excerpt: "let first = items.first!\nprint(first)", lastLine: 12)
        let placement = ReviewPlacement.place([range], in: lines)
        #expect(placement.below[4]?.count == 1)
    }

    @Test func aRangeAcrossHiddenContextKeepsItsLineOffsets() throws {
        let lines = separatedChanges()
        let anchor = DiffAnchor(side: .new, line: 10, lastLine: 20)
        let quote = NumberedDiffLine.excerpt(anchor, in: lines)
        #expect(quote.text == "newFirst()\nnewLast()")
        #expect(quote.offsets == [0, 10])
        let note = ReviewComment(root: "/repo", path: "App.swift", anchor: anchor,
                                 excerpt: quote.text, body: "Keep these calls together.",
                                 excerptOffsets: quote.offsets)
        let reopened = try JSONDecoder().decode(ReviewComment.self, from: JSONEncoder().encode(note))
        let placement = ReviewPlacement.place([reopened], in: lines)
        #expect(placement.unplaced.isEmpty)
        #expect(placement.below[6]?.map(\.id) == [note.id])

        let moved = ReviewPlacement.locate(anchor, excerpt: quote.text, excerptOffsets: quote.offsets,
                                           in: NumberedDiffLine.lines(separatedChanges(start: 30)))
        #expect(moved?.anchor == DiffAnchor(side: .new, line: 30, lastLine: 40))

        var expanded = lines
        expanded.replaceSubrange(3...3, with: (11...19).map {
            DiffLine(id: 100 + $0, kind: .context, text: " context\($0)")
        })
        #expect(ReviewPlacement.place([note], in: expanded).below[6]?.count == 1)

        var changed = lines
        changed[6].text = "+differentLast()"
        #expect(ReviewPlacement.place([note], in: changed).unplaced.map(\.id) == [note.id])
    }

    @Test func aRemovedRangeIncludesUnchangedLinesBetweenTheDeletions() {
        let lines = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -10,3 +10,3 @@"),
            DiffLine(id: 1, kind: .deletion, text: "-oldFirst()"),
            DiffLine(id: 2, kind: .addition, text: "+newFirst()"),
            DiffLine(id: 3, kind: .context, text: " unchanged()"),
            DiffLine(id: 4, kind: .deletion, text: "-oldLast()"),
            DiffLine(id: 5, kind: .addition, text: "+newLast()")
        ]
        let anchor = DiffAnchor(side: .old, line: 10, lastLine: 12)
        let quote = NumberedDiffLine.excerpt(anchor, in: lines)
        #expect(quote.text == "oldFirst()\nunchanged()\noldLast()")
        #expect(quote.offsets == [0, 1, 2])
        let note = ReviewComment(root: "/repo", path: "App.swift", anchor: anchor,
                                 excerpt: quote.text, body: "Keep these calls.", excerptOffsets: quote.offsets)
        #expect(ReviewPlacement.place([note], in: lines).below[4]?.count == 1)
    }

    @Test func commentsSavedWithoutOffsetsStillLoadAndFollowTheirCode() throws {
        let note = comment(.new, 9, excerpt: "let first = items.first!\nprint(first)", lastLine: 10)
        let data = try JSONEncoder().encode(note)
        #expect(!String(decoding: data, as: UTF8.self).contains("excerptOffsets"))
        let reopened = try JSONDecoder().decode(ReviewComment.self, from: data)
        #expect(reopened.excerptOffsets == nil)
        #expect(ReviewPlacement.place([reopened], in: lines).below[4]?.count == 1)
    }

    private func separatedChanges(start: Int = 10) -> [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -\(start),1 +\(start),1 @@"),
         DiffLine(id: 1, kind: .deletion, text: "-oldFirst()"),
         DiffLine(id: 2, kind: .addition, text: "+newFirst()"),
         DiffLine(id: 3, kind: .gap, text: "", gap: DiffGap(
            revision: .workingTree, path: "App.swift", id: 0, start: start + 1, count: 9)),
         DiffLine(id: 4, kind: .hunk, text: "@@ -\(start + 10),1 +\(start + 10),1 @@"),
         DiffLine(id: 5, kind: .deletion, text: "-oldLast()"),
         DiffLine(id: 6, kind: .addition, text: "+newLast()")]
    }

    @Test func shiftClickStretchesARunEitherWay() {
        let start = DiffAnchor(side: .new, line: 12)
        #expect(start.extended(to: DiffAnchor(side: .new, line: 15)) == DiffAnchor(side: .new, line: 12, lastLine: 15))
        #expect(start.extended(to: DiffAnchor(side: .new, line: 9)) == DiffAnchor(side: .new, line: 9, lastLine: 12))
        // A run cannot cross from one version of the file to the other.
        #expect(start.extended(to: DiffAnchor(side: .old, line: 3)) == DiffAnchor(side: .old, line: 3))
        #expect(DiffAnchor(side: .new, line: 4, lastLine: 4).lastLine == nil)
    }

    @Test func anchorKeysRoundTrip() {
        let anchor = DiffAnchor(side: .old, line: 42)
        #expect(DiffComments.anchor(DiffComments.key(anchor)) == anchor)
        #expect(DiffComments.keys(DiffAnchor(side: .new, line: 3, lastLine: 5)) == ["new:3", "new:4", "new:5"])
    }

    @Test func thePromptQuotesEachCommentInFileOrder() throws {
        var second = comment(.new, 12, excerpt: "print(first)", body: "Remove the debug print.")
        second.author = .agent(.codex)
        let prompt = ReviewPrompt.feedback([
            second,
            comment(.new, 11, excerpt: "let first = items.first!", body: "This crashes on an empty list.")
        ])
        #expect(prompt.hasPrefix("I reviewed your changes and left 2 comments."))
        let first = try #require(prompt.range(of: "1. App.swift, line 11\n```\nlet first = items.first!\n```\nThis crashes on an empty list."))
        let later = try #require(prompt.range(of: "2. App.swift, line 12 (raised in a Codex review)"))
        #expect(first.lowerBound < later.lowerBound)
    }

    @Test func notesOnTheSameLinesQuoteThemOnce() {
        let prompt = ReviewPrompt.feedback([
            comment(.new, 12, excerpt: "print(first)", body: "One"),
            comment(.new, 12, excerpt: "print(first)", body: "Two")
        ])
        #expect(prompt.components(separatedBy: "print(first)").count == 2)
        #expect(prompt.contains("2. App.swift, line 12, the same code as above\nTwo"))
    }

    @Test func thePromptNamesTheProjectOnlyInAWorkspace() {
        let app = comment(.new, 11, excerpt: "x", body: "One")
        var api = comment(.old, 3, excerpt: "y", body: "Two", lastLine: 4)
        api.root = "/api"
        let prompt = ReviewPrompt.feedback([app, api], projectNames: ["/repo": "web", "/api": "server"])
        #expect(prompt.contains("web/App.swift, line 11"))
        #expect(prompt.contains("server/App.swift, removed lines 3–4 of the previous version"))
        #expect(!ReviewPrompt.feedback([app]).contains("web/"))
        #expect(ReviewPrompt.feedback([app]).hasPrefix("I reviewed your changes and left a comment. Please address it."))
    }

    @Test func theStoreKeepsCommentsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        let store = ReviewCommentStore(url: url)
        store.add(comment(.new, 11, excerpt: "x"), to: session)
        store.flush()

        let reopened = ReviewCommentStore(url: url)
        #expect(reopened.comments(session).count == 1)
        #expect(reopened.count(session, root: "/repo", path: "App.swift") == 1)
        reopened.clear(session)
        reopened.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRangeMatchesOnEveryLineNotJustItsLast() {
        // Left on a block that ended in a brace; the block is gone, and a brace elsewhere
        // must not take the comment.
        let braces: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,3 +1,3 @@"),
            DiffLine(id: 1, kind: .context, text: " if ready {"),
            DiffLine(id: 2, kind: .context, text: "     start()"),
            DiffLine(id: 3, kind: .context, text: " }")]
        let gone = comment(.new, 7, excerpt: "guard let items else {\n    return\n}", lastLine: 9)
        #expect(ReviewPlacement.place([gone], in: braces).unplaced.count == 1)
    }

    @Test func plainCodeThatMovedToOneOfSeveralPlacesIsNotGuessed() {
        let braces: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,4 +1,4 @@"),
            DiffLine(id: 1, kind: .context, text: " }"),
            DiffLine(id: 2, kind: .context, text: " start()"),
            DiffLine(id: 3, kind: .context, text: " }")]
        // On its own line it still holds, whatever it says.
        #expect(ReviewPlacement.place([comment(.new, 1, excerpt: "}")], in: braces).below[1]?.count == 1)
        // Moved, a lone brace could be either one.
        #expect(ReviewPlacement.place([comment(.new, 9, excerpt: "}")], in: braces).unplaced.count == 1)
    }

    @Test func aRunFollowsItsCodeAndKeepsItsLength() {
        let moved = ReviewPlacement.locate(DiffAnchor(side: .new, line: 9, lastLine: 10),
                                           excerpt: "let first = items.first!\nprint(first)",
                                           in: NumberedDiffLine.lines(lines))
        #expect(moved?.anchor == DiffAnchor(side: .new, line: 11, lastLine: 12))
        #expect(moved?.lastID == 4)
    }

    @Test func sendingTakesOnlyTheCommentsThatWereSent() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let sent = comment(.new, 11, excerpt: "x")
        let arrivedLater = comment(.new, 12, excerpt: "y")
        store.add(sent, to: session)
        store.add(arrivedLater, to: session)
        store.remove([sent.id], from: session)
        #expect(store.comments(session).map(\.id) == [arrivedLater.id])
    }

    @Test func aWorkspaceNamesTheProjectEvenWhenOnlyOneHasComments() {
        var api = comment(.new, 3, excerpt: "y", body: "Two")
        api.root = "/api"
        let prompt = ReviewPrompt.feedback([api], projectNames: ["/repo": "web", "/api": "server"])
        #expect(prompt.contains("server/App.swift, line 3"))
    }

    // MARK: - Drawing

    @Test func numbersCarryTheirLineAndThreadsGetARowOfTheirOwn() {
        let text = DiffText.attributed(lines, numbered: true, comments: DiffComments(threads: [3]))
        var keys: Set<String> = []
        var threads: [String] = []
        text.enumerateAttribute(.diffLineAnchor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let key = value as? String { keys.insert(key) }
        }
        text.enumerateAttribute(.diffThread, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let id = value as? String {
                threads.append(id)
                #expect(range.length == 1)
            }
        }
        #expect(keys == ["new:10", "old:11", "new:11", "new:12", "new:13"])
        #expect(threads == ["3"])
        // The row sits right after the line it hangs from.
        let rows = text.string.components(separatedBy: "\n")
        #expect(rows[3].hasSuffix("let first = items.first!"))
        #expect(rows[4] == " ")
    }

    @Test func aDiffWithNowhereToSendCommentsHasNoAnchors() {
        let text = DiffText.attributed(lines, numbered: true)
        var found = false
        text.enumerateAttribute(.diffLineAnchor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { found = true }
        }
        #expect(!found)
    }

    // MARK: - Findings, kinds and rounds

    @Test func reviewsSavedBeforeFindingsCouldWaitStillLoad() throws {
        let saved = #"{"id":"\#(UUID().uuidString)","root":"/repo","path":"App.swift","side":"new","line":3,"excerpt":"x","body":"Fix","author":{"you":{}},"created":0}"#
        let comment = try JSONDecoder().decode(ReviewComment.self, from: Data(saved.utf8))
        #expect(comment.status == .kept)
        #expect(comment.kind == .change)
        #expect(comment.also.isEmpty)
        #expect(!comment.onFile)
    }

    @Test func twoSeatsOfOneAgentOnDifferentModelsAreTwoVoices() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        var sol = comment(.new, 12, excerpt: "y", body: "Off by one")
        sol.author = .agent(.codex)
        sol.reviewerModel = "Sol high"
        var luna = comment(.new, 12, excerpt: "y", body: "Loop ends early")
        luna.author = .agent(.codex)
        luna.reviewerModel = "Luna"
        store.finishSecondOpinion(session, reviewer: .init(agent: .codex, model: "gpt-5.6-sol"), outcome: .success([sol]))
        store.finishSecondOpinion(session, reviewer: .init(agent: .codex, model: "gpt-5.6-luna"), outcome: .success([luna]))
        let merged = store.pending(session)
        #expect(merged.count == 1)
        #expect(merged.first?.voices.map(\.name) == ["Codex on Sol high", "Codex on Luna"])
    }

    @Test func aFindingIsNeverSentUntilItIsKept() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        store.add(comment(.new, 11, excerpt: "x", body: "Mine"), to: session)
        var finding = comment(.new, 12, excerpt: "y", body: "Theirs")
        finding.author = .agent(.codex)
        store.finishSecondOpinion(session, reviewer: .init(agent: .codex), outcome: .success([finding]))
        #expect(store.pending(session).map(\.body) == ["Theirs"])
        #expect(store.kept(session).map(\.body) == ["Mine"])

        store.keep(finding.id, in: session)
        #expect(store.pending(session).isEmpty)
        #expect(store.kept(session).count == 2)
    }

    @Test func editingAFindingKeepsItAndSaysSo() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        var finding = comment(.new, 12, excerpt: "y", body: "Theirs")
        finding.author = .agent(.copilot)
        store.addFindings([finding], from: .copilot, to: session)
        store.update(finding.id, body: "Theirs, in my words", kind: .question, in: session)
        let kept = store.comment(finding.id, in: session)
        #expect(kept?.status == .kept)
        #expect(kept?.edited == true)
        #expect(kept?.kind == .question)
    }

    @Test func twoReviewersOnTheSameLinesReadAsOneFinding() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        var codex = comment(.new, 12, excerpt: "y", body: "Two pods can send this twice.")
        codex.author = .agent(.codex)
        codex.severity = .should
        var copilot = comment(.new, 12, excerpt: "y", body: "No lock is taken.")
        copilot.author = .agent(.copilot)
        copilot.severity = .must
        var elsewhere = comment(.new, 11, excerpt: "x", body: "Something else.")
        elsewhere.author = .agent(.copilot)
        store.addFindings([codex], from: .codex, to: session)
        let added = store.addFindings([copilot, elsewhere], from: .copilot, to: session)
        #expect(added == 1)
        let merged = store.comment(codex.id, in: session)
        #expect(merged?.also == [.init(agent: .copilot, body: "No lock is taken.")])
        #expect(merged?.authorName == "Codex and Copilot")
        #expect(merged?.severity == .must)
        #expect(store.comments(session).count == 2)
        #expect(ReviewPrompt.feedback([merged!]).contains("(raised in a Codex and Copilot review)"))
    }

    @Test func aDismissedFindingComesBackInItsPlace() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let first = comment(.new, 10, excerpt: "a", body: "One")
        let second = comment(.new, 11, excerpt: "b", body: "Two")
        let third = comment(.new, 12, excerpt: "c", body: "Three")
        store.add([first, second, third], to: session)
        let gone = store.dismiss(second.id, from: session)
        #expect(store.comments(session).map(\.body) == ["One", "Three"])
        store.restore(gone!.comment, at: gone!.index, to: session)
        #expect(store.comments(session).map(\.body) == ["One", "Two", "Three"])
    }

    @Test func aFailedReviewerLeavesTheOthersFindingsAndCanTryAgain() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        var finding = comment(.new, 12, excerpt: "y", body: "From Codex")
        finding.author = .agent(.codex)
        store.finishSecondOpinion(session, reviewer: .init(agent: .codex), outcome: .success([finding]))

        let request = SecondOpinionRequest(repositories: [ReviewRepository(root: scratch.path, name: "App")],
                                           executable: "/usr/bin/false")
        store.startSecondOpinion(session, reviewer: .init(agent: .copilot), request: request)
        #expect(store.isReviewing(session, reviewer: .init(agent: .copilot)))
        #expect(await waitUntil { store.runs(session).first?.state == .failed("There are no changes to review.") })
        #expect(store.pending(session).map(\.body) == ["From Codex"])

        store.retrySecondOpinion(session, reviewer: .init(agent: .copilot))
        #expect(store.runs(session).first?.isRunning == true)
        store.stopSecondOpinion(session, reviewer: .init(agent: .copilot))
        #expect(store.runs(session).isEmpty)
    }

    @Test func steppingGoesRoundTheReviewInFileOrder() {
        var other = comment(.new, 1, excerpt: "z", body: "Other file")
        other.path = "Zed.swift"
        let removed = comment(.old, 2, excerpt: "a", body: "Removed")
        let added = comment(.new, 30, excerpt: "b", body: "Added")
        let ordered = ReviewOrder.sorted([other, removed, added])
        #expect(ordered.map(\.body) == ["Added", "Removed", "Other file"])
        #expect(ReviewOrder.step(from: nil, by: 1, in: ordered)?.body == "Added")
        #expect(ReviewOrder.step(from: nil, by: -1, in: ordered)?.body == "Other file")
        #expect(ReviewOrder.step(from: other.id, by: 1, in: ordered)?.body == "Added")
        #expect(ReviewOrder.step(from: added.id, by: -1, in: ordered)?.body == "Other file")
    }

    @Test func questionsAndTheRoundNoteAreSpelledOut() {
        var question = comment(.new, 11, excerpt: "x", body: "Why eight attempts?")
        question.kind = .question
        var onFile = comment(.new, 40, excerpt: "gone()", body: "Keep the warning.")
        onFile.onFile = true
        let prompt = ReviewPrompt.feedback([question, onFile], note: " Run the tests when you are done. ")
        #expect(prompt.contains("A comment marked as a question only needs an answer, not a code change."))
        #expect(prompt.contains("App.swift, line 11 (a question)"))
        #expect(prompt.contains("App.swift, the whole file"))
        #expect(prompt.hasSuffix("One more thing: Run the tests when you are done."))
        #expect(!ReviewPrompt.feedback([comment(.new, 11, excerpt: "x")]).contains("question"))
    }

    @Test func aCommentWhoseCodeWasLeftAloneWasNotChanged() {
        let note = comment(.new, 2, excerpt: "let first = items.first!", body: "Guard it")
        let file = "let items = load()\nlet first = items.first!\nreturn first"
        #expect(ReviewRound.outcome(for: note, fileText: file, digestAtSend: nil) == .unchanged)
        let edited = "let items = load()\nguard let first = items.first else { return nil }\nreturn first"
        #expect(ReviewRound.outcome(for: note, fileText: edited, digestAtSend: nil) == .changed)
        let moved = "// header\nlet items = load()\nlet first = items.first!\nreturn first"
        #expect(ReviewRound.outcome(for: note, fileText: moved, digestAtSend: nil) == .changed)
        #expect(ReviewRound.outcome(for: note, fileText: nil, digestAtSend: nil) == .changed)
        var question = note
        question.kind = .question
        #expect(ReviewRound.outcome(for: question, fileText: file, digestAtSend: nil) == .answered)
        let removed = comment(.old, 2, excerpt: "let first = items[0]", body: "Why?")
        #expect(ReviewRound.outcome(for: removed, fileText: file, digestAtSend: ReviewRound.digest(file)) == .unchanged)
        #expect(ReviewRound.outcome(for: removed, fileText: edited, digestAtSend: ReviewRound.digest(file)) == .changed)
    }

    @Test func aSentReviewIsSettledWhenItsTurnEndsWithEachAnswerInItsThread() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("rounds.json"))
        }
        let store = ReviewCommentStore(url: url)
        let files = FileBox(["/repo/App.swift": "let items = load()\nlet first = items.first!\nreturn first"])
        store.readFile = { files.read($0) }
        let session = UUID()
        let untouched = comment(.new, 2, excerpt: "let first = items.first!", body: "Guard it")
        var question = comment(.new, 3, excerpt: "return first", body: "Why return here?")
        question.kind = .question
        let unsent = comment(.new, 1, excerpt: "let items = load()", body: "Later")
        store.add([untouched, question, unsent], to: session)

        let prompt = ReviewPrompt.feedback([untouched, question])
        let round = store.recordRound([untouched, question], prompt: prompt, note: "", roots: [], in: session)
        #expect(store.comments(session).map(\.body) == ["Later"])
        #expect(store.round(prompt: "  " + prompt + "\n", in: session)?.id == round.id)
        #expect(store.threads(session).map(\.comment.id) == [untouched.id, question.id])

        await store.turnEnded(session, prompt: "Something else")
        #expect(store.rounds(session).first?.isSettled == false)
        #expect(store.rounds(session).first?.status(untouched.id) == .waiting)
        let reply = ChatMessage(role: .assistant, text: """
        I looked at both.

        ### Comment 1
        It cannot be empty here, so I left it.

        ### Comment 2
        It returns early so the caller sees the first item.
        I can add a comment that says so.
        Suggested reply: "Yes, add it"
        """)
        await store.turnEnded(session, prompt: prompt, reply: reply)
        let settled = try #require(store.rounds(session).first)
        #expect(settled.status(untouched.id) == .unchanged)
        #expect(settled.status(question.id) == .answered)
        #expect(settled.replies(untouched.id).map(\.body) == ["It cannot be empty here, so I left it."])
        #expect(settled.replies(question.id).first?.suggestion == "Yes, add it")
        #expect(settled.replies(question.id).first?.body.hasSuffix("I can add a comment that says so.") == true)
        #expect(store.unreadCount(session) == 2)

        store.markRead(untouched.id, in: session)
        store.resolve(untouched.id, round: round.id, in: session)
        #expect(store.unreadCount(session) == 1)
        #expect(store.rounds(session).first?.status(untouched.id) == .resolved)
        store.reopen(untouched.id, round: round.id, in: session)
        #expect(store.rounds(session).first?.status(untouched.id) == .unchanged)
        store.flush()

        let reopened = ReviewCommentStore(url: url)
        let saved = try #require(reopened.rounds(session).first)
        #expect(saved.outcomes?[question.id] == .answered)
        #expect(saved.replies(question.id).first?.suggestion == "Yes, add it")
        #expect(saved.unread == [question.id])
    }

    @Test func aReplyInAThreadGoesAtOnceAndItsAnswerJoinsTheThread() async throws {
        let store = ReviewCommentStore(url: nil)
        let files = FileBox(["/repo/App.swift": "let items = load()\nlet first = items.first!\nreturn first"])
        store.readFile = { files.read($0) }
        let session = UUID()
        var question = comment(.new, 2, excerpt: "let first = items.first!", body: "What if it is empty?")
        question.kind = .question
        let prompt = ReviewPrompt.feedback([question])
        let round = store.recordRound([question], prompt: prompt, note: "", roots: [], in: session)
        await store.turnEnded(session, prompt: prompt,
                              reply: ChatMessage(role: .assistant, text: "It would crash. I can guard it."))
        #expect(store.rounds(session).first?.replies(question.id).map(\.body) == ["It would crash. I can guard it."])

        let sent = try #require(await store.reply("Yes, guard it", to: question.id, round: round.id, in: session))
        #expect(sent.contains("A follow-up on my review comment 1, on App.swift, line 2."))
        #expect(sent.contains("You answered: It would crash. I can guard it."))
        #expect(sent.contains("My reply: Yes, guard it"))
        #expect(sent.contains("### Comment 1"))
        #expect(store.isThreadReply(prompt: sent, in: session))
        #expect(store.rounds(session).first?.status(question.id) == .waiting)

        files.files["/repo/App.swift"] = "let items = load()\nguard let first = items.first else { return nil }\nreturn first"
        await store.turnEnded(session, prompt: sent, reply: ChatMessage(role: .assistant, text: """
        Let me edit it.
        ### Comment 1
        Done, it returns nil when the list is empty.
        """))
        let answered = try #require(store.rounds(session).first)
        #expect(answered.replies(question.id).map(\.author) == [.agent, .you, .agent])
        #expect(answered.replies(question.id).last?.body == "Done, it returns nil when the list is empty.")
        #expect(answered.status(question.id) == .changed)
        #expect(answered.replies(question.id).last?.diff == [
            ReviewDiffLine(kind: .deletion, number: 2, text: "let first = items.first!"),
            ReviewDiffLine(kind: .addition, number: 2, text: "guard let first = items.first else { return nil }")
        ])
        // The same turn ending twice does not answer twice.
        await store.turnEnded(session, prompt: sent, reply: nil)
        #expect(store.rounds(session).first?.replies(question.id).count == 3)
    }

    @Test func answersAreSplitByTheirHeadingsAndTheRestIsLeftInPlace() throws {
        let text = "I made the changes.\n\n## Comment 2 - App.swift\nSecond.\n\n**Comment 1**\nFirst.\n- Suggested reply: Move them\n"
        let found = try #require(ReviewAnswers.split(text))
        #expect(String(text.prefix(found.start)) == "I made the changes.\n\n")
        #expect(found.answers[1] == .init(body: "First.", suggestion: "Move them"))
        #expect(found.answers[2] == .init(body: "Second.", suggestion: nil))
        #expect(ReviewAnswers.split("Comment 1 is fine as it is.") == nil)

        var turn = ChatMessage(role: .assistant, text: "Reading the file.Done, the name is clearer now.")
        turn.tools = [ToolUse(id: "1", name: "Edit", input: "{}", textOffset: 17)]
        let single = try #require(ReviewAnswers.read(turn, count: 1))
        #expect(single.start == 17)
        #expect(single.answers[1]?.body == "Done, the name is clearer now.")
        #expect(ReviewAnswers.read(turn, count: 2) == nil)
        #expect(turn.cut(at: single.start).text == "Reading the file.")
        #expect(turn.cut(at: single.start).tools.count == 1)
    }

    @Test func aThreadShowsOnlyTheChangesNearItsLines() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var after = before.components(separatedBy: "\n")
        after[1] = "changed 2"
        after[15] = "changed 16"
        let near = ReviewDiffLine.near(comment(.new, 15, excerpt: "line 15"), before: before,
                                       after: after.joined(separator: "\n"))
        #expect(near == [ReviewDiffLine(kind: .deletion, number: 16, text: "line 16"),
                         ReviewDiffLine(kind: .addition, number: 16, text: "changed 16")])
        #expect(ReviewDiffLine.near(comment(.new, 15, excerpt: "line 15"), before: before, after: before).isEmpty)
    }

    @Test func roundsSavedBeforeThreadsStillLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sent":0,"prompt":"Fix it","note":"","comments":[],
         "fileDigests":{},"trees":{},"returned":[]}
        """
        let round = try JSONDecoder().decode(ReviewRound.self, from: Data(json.utf8))
        #expect(round.replies.isEmpty && round.resolved.isEmpty && round.unread.isEmpty)
        #expect(!round.isSettled)
    }

    @Test func thePromptAsksForAnAnswerUnderEachComment() {
        let prompt = ReviewPrompt.feedback([comment(.new, 11, excerpt: "x")])
        #expect(prompt.contains("`### Comment 1`, `### Comment 2` and so on"))
        #expect(prompt.contains("Suggested reply:"))
    }
}

// Hands a test's made-up files to the store in place of the disk.
private final class FileBox: @unchecked Sendable {
    var files: [String: String]
    init(_ files: [String: String]) { self.files = files }
    func read(_ path: String) -> String? { files[path] }
}

// Another agent's review comes back as text that should be a JSON array of findings,
// which are turned into comments on the lines they name.
struct SecondOpinionTests {

    private let patch = SecondOpinion.Patch(root: "/repo", path: "Sources/App.swift", label: "Sources/App.swift",
                                            text: """
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,3 +10,4 @@
     let items = load()
    -let first = items[0]
    +let first = items.first!
    +print(first)
     return first
    """)

    @Test func findingsAreReadOutOfAWrappedAnswer() {
        let answer = """
        Here is what I found:
        ```json
        [{"file": "Sources/App.swift", "line": 11, "comment": "Crashes when [items] is empty."}]
        ```
        """
        let findings = SecondOpinion.findings(in: answer)
        #expect(findings == [SecondOpinion.Finding(file: "Sources/App.swift", line: 11,
                                                   comment: "Crashes when [items] is empty.")])
    }

    @Test func anEmptyArrayMeansNothingFoundButProseMeansUnreadable() {
        #expect(SecondOpinion.findings(in: "[]") == [])
        #expect(SecondOpinion.findings(in: "Looks good to me!") == nil)
        #expect(SecondOpinion.findings(in: "see [1] and [2]") == nil)
    }

    @Test func bracketsInsideStringsDoNotSplitTheArray() {
        let arrays = SecondOpinion.jsonArrays(in: #"x [{"comment": "a ] b"}] y [1]"#)
        #expect(arrays == [#"[{"comment": "a ] b"}]"#, "[1]"])
    }

    @Test func aPatchKnowsTheCodeOnEachNumberedLine() {
        let new = SecondOpinion.newLines(in: patch.text)
        #expect(new[10] == "let items = load()")
        #expect(new[11] == "let first = items.first!")
        #expect(new[13] == "return first")
        #expect(SecondOpinion.oldLines(in: patch.text)[11] == "let first = items[0]")
    }

    @Test func findingsBecomeCommentsByTheReviewer() {
        let findings = [
            SecondOpinion.Finding(file: "Sources/App.swift", line: 11, comment: " Crashes on empty. "),
            SecondOpinion.Finding(file: "Other.swift", line: 1, comment: "Not in the diff"),
            SecondOpinion.Finding(file: "Sources/App.swift", line: 12, comment: "")
        ]
        let comments = SecondOpinion.comments(from: findings, patches: [patch], agent: .codex)
        #expect(comments.count == 1)
        #expect(comments[0].body == "Crashes on empty.")
        #expect(comments[0].excerpt == "let first = items.first!")
        #expect(comments[0].author == .agent(.codex))
        #expect(comments[0].anchor == DiffAnchor(side: .new, line: 11))
    }

    @Test func thePromptIncludesEveryPatchThatFits() {
        let prompt = SecondOpinion.prompt(for: [patch])
        #expect(prompt.contains("File: Sources/App.swift\nPath: /repo/Sources/App.swift\ndiff --git"))
        #expect(prompt.contains("Reply with only a JSON array"))
    }

    @Test func eachReviewerRunsReadOnly() {
        let claude = SecondOpinion.arguments(for: .claudeCode, prompt: "p")
        #expect(claude.contains("--disallowedTools"))
        let codex = SecondOpinion.arguments(for: .codex, prompt: "p")
        #expect(codex.contains("read-only"))
        #expect(codex.last == "p")
    }

    @Test func eachSeatRunsOnItsOwnModelAndEffort() throws {
        let claude = SecondOpinion.arguments(for: .init(agent: .claudeCode, model: "sonnet", effort: "high"), prompt: "p")
        #expect(claude.contains(["--model", "sonnet"]) && claude.contains(["--effort", "high"]))
        let codex = SecondOpinion.arguments(for: .init(agent: .codex, model: "gpt-5.6-sol", effort: "xhigh"), prompt: "p")
        #expect(codex.contains(["--model", "gpt-5.6-sol"]))
        #expect(codex.contains(["-c", #"model_reasoning_effort="xhigh""#]))
        #expect(codex.last == "p")
        let copilot = SecondOpinion.arguments(for: .init(agent: .copilot, model: "gpt-5.4", effort: "low"), prompt: "p")
        #expect(copilot.contains(["--model", "gpt-5.4"]) && copilot.contains(["--effort", "low"]))
        let plain = SecondOpinion.arguments(for: .codex, prompt: "p")
        #expect(!plain.contains("--model"))
        #expect(!plain.contains { $0.hasPrefix("model_reasoning_effort") })
    }

    @Test func independenceIsMeasuredAgainstTheAuthorsModel() {
        let author = SecondOpinion.Reviewer(agent: .claudeCode, model: "opus", effort: "high")
        func level(_ agent: AgentKind, _ model: String?) -> SecondOpinion.Independence {
            SecondOpinion.independence(of: .init(agent: agent, model: model), from: author)
        }
        #expect(level(.codex, "gpt-5.6-sol") == .differentMaker)
        #expect(level(.copilot, "gpt-5.4") == .differentMaker)
        #expect(level(.copilot, "claude-sonnet-5") == .otherModel)
        #expect(level(.claudeCode, "sonnet") == .otherModel)
        #expect(level(.claudeCode, "opus") == .sameModel)
        #expect(level(.copilot, "claude-opus-5") == .sameModel)
        #expect(level(.copilot, nil) == .unknown)
        #expect(level(.copilot, "auto") == .unknown)
        let onDefault = SecondOpinion.Reviewer(agent: .claudeCode)
        #expect(SecondOpinion.independence(of: onDefault, from: onDefault) == .sameModel)
    }

    @Test func aSeatIsNamedByItsModelAndEffort() {
        let seat = SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol", effort: "high")
        #expect(seat.label() == "Codex on Sol high")
        #expect(seat.seatLabel == "Sol high")
        #expect(SecondOpinion.Reviewer(agent: .codex).seatLabel == nil)
        let findings = [SecondOpinion.Finding(file: "Sources/App.swift", line: 11, comment: "Crashes.")]
        let comment = SecondOpinion.comments(from: findings, patches: [patch], agent: .codex, model: seat.seatLabel)
        #expect(comment.first?.authorName == "Codex on Sol high")
    }

    @Test func theUsualLineupIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "lineup-\(UUID().uuidString)"))
        #expect(Preferences.secondOpinionLineup(in: defaults).isEmpty)
        let lineup = [SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol", effort: "high"),
                      SecondOpinion.Reviewer(agent: .copilot, model: "claude-sonnet-5")]
        Preferences.setSecondOpinionLineup(lineup, in: defaults)
        #expect(Preferences.secondOpinionLineup(in: defaults) == lineup)
    }

    @Test func aLineupTakesAsLongAsItsSlowestSeat() {
        #expect(SecondOpinion.minutes(for: "low") < SecondOpinion.minutes(for: "xhigh"))
        #expect(SecondOpinion.minutes(for: nil) == SecondOpinion.minutes(for: "high"))
    }

    @Test func noReviewerGetsThePersonsMCPServersOrWriteAccess() throws {
        let codex = SecondOpinion.arguments(for: .codex, prompt: "p", codexServers: [
            DisabledMCPServer(name: "files", transport: .stdio),
            DisabledMCPServer(name: "remote", transport: .streamableHTTP)
        ])
        #expect(codex.contains(#"mcp_servers={"files"={enabled=false,command="/usr/bin/false"},"remote"={enabled=false,url="https://disabled.invalid"}}"#))
        let copilot = SecondOpinion.arguments(for: .copilot, prompt: "p", copilotServers: ["files"])
        #expect(copilot.contains("--deny-tool=shell"))
        #expect(copilot.contains("--deny-tool=write"))
        #expect(copilot.contains("--deny-tool=files"))
        let disabled = try #require(copilot.firstIndex(of: "--disable-mcp-server"))
        #expect(copilot[disabled + 1] == "files")
    }

    @Test func copilotsServersAreReadFromItsOwnConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mcpServers": {"files": {}, "browser": {}}}"#.utf8).write(to: url)
        #expect(SecondOpinion.copilotServers(in: url) == ["browser", "files"])
        #expect(SecondOpinion.copilotServers(in: url.appendingPathExtension("missing")).isEmpty)
    }

    @Test func claudesAnswerIsItsResultField() {
        let output = #"{"type":"result","subtype":"success","result":"[]","is_error":false}"#
        #expect(SecondOpinion.answer(from: output, agent: .claudeCode) == "[]")
    }

    @Test func workspaceRootsAndOmittedFilesHaveTheirActualPaths() {
        var attached = patch
        attached.root = "/worktrees/api-123"
        attached.label = "API/Sources/App.swift"
        attached.text = String(repeating: "x", count: SecondOpinion.patchBudget + 1)
        let prompt = SecondOpinion.prompt(for: [patch, attached], repositories: [
            (root: "/repo", name: "App"),
            (root: "/worktrees/api-123", name: "API"),
            (root: "/elsewhere/shared-456", name: "Shared")
        ])
        #expect(prompt.contains("- API: /worktrees/api-123"))
        #expect(prompt.contains("- Shared: /elsewhere/shared-456"))
        #expect(prompt.contains("File: API/Sources/App.swift\nPath: /worktrees/api-123/Sources/App.swift"))
        #expect(!prompt.contains(attached.text))
    }

    @Test(arguments: [AgentKind.claudeCode, .copilot, .codex])
    func attachedProjectsCanBeReadWithoutEnablingWrites(_ agent: AgentKind) {
        let roots = ["/worktrees/attached project", "/elsewhere/shared"]
        let arguments = SecondOpinion.arguments(for: agent, prompt: "p", addDirectories: roots)
        if agent == .codex {
            #expect(arguments.contains("read-only"))
            #expect(!arguments.contains("--add-dir"))
        } else if agent == .claudeCode {
            let start = arguments.firstIndex(of: "--add-dir")
            #expect(start != nil)
            #expect(start.map { Array(arguments.dropFirst($0 + 1)) } == roots)
            #expect(arguments.contains("--disallowedTools"))
        } else {
            let granted = arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
            #expect(granted == roots)
            #expect(arguments.contains("--deny-tool=write"))
        }
    }

    @Test func findingsArriveWaitingWithTheirSeverity() {
        let findings = [SecondOpinion.Finding(file: "Sources/App.swift", line: 11, comment: "Crashes.", severity: "MUST")]
        let comments = SecondOpinion.comments(from: findings, patches: [patch], agent: .codex)
        #expect(comments.first?.status == .pending)
        #expect(comments.first?.severity == .must)
        let read = SecondOpinion.findings(in: #"[{"file":"a","line":1,"severity":"look","comment":"c"}]"#)
        #expect(read?.first?.severity == "look")
    }

    @Test func thePromptAsksForWhatWasPickedAndHowMuchItMatters() {
        let prompt = SecondOpinion.prompt(for: [patch], focus: [.missingTests, .bugs])
        #expect(prompt.contains("bugs and broken behaviour; behaviour the change adds or alters with no test covering it"))
        #expect(!prompt.contains("security issues"))
        #expect(prompt.contains(#""severity": "must" | "should" | "look""#))
        #expect(!prompt.contains("last review was sent"))
        #expect(SecondOpinion.prompt(for: [patch], sinceReview: true).contains("after the author's last review was sent"))
    }

    @Test func aPatchOfManyFilesSplitsIntoOnePerFile() {
        let text = """
        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        --- a/Gone.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let patches = SecondOpinion.split(text, root: "/repo")
        #expect(patches.map(\.path) == ["App.swift", "Gone.swift"])
        #expect(patches.map(\.deleted) == [false, true])
        #expect(patches[0].text.hasPrefix("diff --git a/App.swift"))
        #expect(SecondOpinion.newLines(in: patches[0].text)[1] == "new")
    }

    @Test func aLaneSaysWhatTheReviewerIsReading() {
        func tool(_ name: String, _ input: String) -> ToolUse { ToolUse(id: "1", name: name, input: input) }
        #expect(SecondOpinion.activity(for: tool("Read", #"{"file_path":"/repo/Sources/App.swift"}"#)) == "Reading App.swift")
        #expect(SecondOpinion.activity(for: tool("Grep", #"{"pattern":"retryDue"}"#)) == "Searching for retryDue")
        #expect(SecondOpinion.activity(for: tool("Bash", #"{"command":"rg -n retry src extra"}"#)) == "Running rg -n retry")
        #expect(SecondOpinion.activity(for: tool("WebFetch", "{}")) == "Using WebFetch")
    }

    @Test func claudeStreamsSoItsLaneCanFollowIt() {
        let claude = SecondOpinion.arguments(for: .claudeCode, prompt: "p")
        #expect(claude.contains("stream-json"))
        #expect(claude.contains("--verbose"))
        let stream = #"{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}"# + "\n"
            + #"{"type":"result","subtype":"success","result":"[]","is_error":false}"#
        #expect(SecondOpinion.answer(from: stream, agent: .claudeCode) == "[]")
    }
}
