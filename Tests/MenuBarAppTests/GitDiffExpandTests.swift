import Foundation
import Testing
@testable import MenuBarApp

// A diff only shows a few lines around each change. The gap rows stand for the rest, and
// pressing one has to bring those lines back from the version the diff was made against:
// the file on disk, the staged copy, or the file as a commit left it.
struct GitDiffExpandTests {

    private func file(_ count: Int, changing line: Int? = nil) -> String {
        (1...count).map { number in
            number == line ? "line \(number) changed" : "line \(number)"
        }.joined(separator: "\n") + "\n"
    }

    @Test func aGapKnowsHowManyLinesItHides() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)
        // Three lines of context put the hunk at line 37, so lines 1 to 36 are hidden.
        #expect(gap.start == 1)
        #expect(gap.count == 36)
        #expect(gap.revision == .workingTree)
        #expect(gap.path == "app.txt")
        // The row sits above the header it belongs to, which is where the hole is.
        let at = try #require(diff.lines.firstIndex { $0.gap?.key == gap.key })
        #expect(diff.lines[at].kind == .gap)
        #expect(diff.lines[at + 1].text.hasPrefix("@@"))
    }

    @Test func aShortGapOpensInOneGo() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)
        let opened = await GitInspector.expand(gap, .up, root: repo.path)

        #expect(opened.gap == nil)
        #expect(opened.lines.count == 36)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.last?.text == " line 36")
        #expect(opened.lines.allSatisfy { $0.kind == .context })
    }

    @Test func readingUpOpensTheEndOfTheGapNearestTheChange() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 150))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)
        #expect(gap.count == 146)

        let opened = await GitInspector.expand(gap, .up, root: repo.path)
        #expect(opened.lines.count == 20)
        #expect(opened.lines.first?.text == " line 127")
        #expect(opened.lines.last?.text == " line 146")
        // The hole is still at the top of the file, and shorter by what came back.
        #expect(opened.gap?.start == 1)
        #expect(opened.gap?.count == 126)
        // The row keeps its name while it shrinks, so the pane can find it again.
        #expect(opened.gap?.key == gap.key)
    }

    @Test func readingDownOpensTheEndOfTheGapNearestTheCodeAbove() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 150))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)

        let opened = await GitInspector.expand(gap, .down, root: repo.path)
        #expect(opened.lines.count == 20)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.last?.text == " line 20")
        // What is left starts below the lines just read, so the row still stands for
        // the hole and nothing else.
        #expect(opened.gap?.start == 21)
        #expect(opened.gap?.count == 126)
        #expect(opened.gap?.key == gap.key)
    }

    @Test func openingTheWholeGapLeavesNothingBehind() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 150))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)

        let opened = await GitInspector.expand(gap, .all, root: repo.path)
        #expect(opened.gap == nil)
        #expect(opened.lines.count == 146)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.last?.text == " line 146")
    }

    @Test func bothEndsOfTheSameGapMeetInTheMiddle() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 150))

        let diff = await diff(of: "app.txt", in: repo)
        var gap = diff.lines.compactMap(\.gap).first
        var read: [String] = []
        // Alternating ends has to walk the hole shut without reading a line twice or
        // stepping over one.
        var step = 0
        while let open = gap, step < 20 {
            let opened = await GitInspector.expand(open, step.isMultiple(of: 2) ? .down : .up,
                                                   root: repo.path)
            read.append(contentsOf: opened.lines.map(\.text))
            gap = opened.gap
            step += 1
        }
        #expect(gap == nil)
        #expect(read.count == 146)
        #expect(Set(read).count == 146)
        #expect(read.contains(" line 1"))
        #expect(read.contains(" line 146"))
    }

    @Test func theSecondGapStartsWhereTheFirstHunkEnded() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        var lines = (1...200).map { "line \($0)" }
        lines[9] = "line 10 changed"
        lines[99] = "line 100 changed"
        try repo.write("app.txt", lines.joined(separator: "\n") + "\n")

        let diff = await diff(of: "app.txt", in: repo)
        let gaps = diff.lines.compactMap(\.gap)
        // One before each hunk, and one for the end of the file.
        #expect(gaps.count == 3)
        // The first hunk covers lines 7 to 13, so the second gap starts at 14.
        #expect(gaps[1].start == 14)
        #expect(gaps[1].count == 83)

        let opened = await GitInspector.expand(gaps[1], .up, root: repo.path)
        #expect(opened.lines.first?.text == " line 77")
        #expect(opened.lines.last?.text == " line 96")
    }

    @Test func theEndOfTheFileGetsARowThatSizesItselfWhenOpened() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let tail = try #require(diff.lines.compactMap(\.gap).last)
        // The diff never says how long the file is, so the row starts out open ended.
        #expect(tail.count == nil)
        // The hunk covers lines 37 to 43, so everything from 44 is still to come.
        #expect(tail.start == 44)
        #expect(diff.lines.last?.gap?.key == tail.key)

        let opened = await GitInspector.expand(tail, .down, root: repo.path)
        #expect(opened.gap == nil)
        #expect(opened.lines.count == 17)
        #expect(opened.lines.first?.text == " line 44")
        #expect(opened.lines.last?.text == " line 60")
    }

    @Test func aLongTailComesBackAStepAtATime() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 10))

        let diff = await diff(of: "app.txt", in: repo)
        let tail = try #require(diff.lines.compactMap(\.gap).last)
        #expect(tail.count == nil)

        let opened = await GitInspector.expand(tail, .down, root: repo.path)
        #expect(opened.lines.count == 20)
        #expect(opened.lines.first?.text == " line 14")
        // Reading the file settles the size, so the row can say what is left.
        #expect(opened.gap?.start == 34)
        #expect(opened.gap?.count == 167)
    }

    @Test func aStagedGapReadsTheStagedCopy() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))
        try repo.git("add", "app.txt")
        // The working copy moves on after staging, so the wrong source would show
        // lines the staged diff never had.
        try repo.write("app.txt", file(60, changing: 40).replacingOccurrences(of: "line 5\n",
                                                                              with: "line 5 later\n"))

        let diff = await diff(of: "app.txt", in: repo)
        let staged = try #require(diff.lines.compactMap(\.gap).first { $0.revision == .index })
        let opened = await GitInspector.expand(staged, .up, root: repo.path)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.contains { $0.text == " line 5" })
        #expect(!opened.lines.contains { $0.text == " line 5 later" })
    }

    @Test func aCommitGapReadsThatCommit() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))
        try repo.commit("change line 40")
        let hash = repo.head
        // Later work must not leak into a diff of an older commit.
        try repo.write("app.txt", file(60, changing: 12))
        try repo.commit("change line 12")

        let diff = await GitInspector.commitDiff(hash, root: repo.path)
        let gap = try #require(diff.lines.compactMap(\.gap).first)
        #expect(gap.revision == .commit(hash))
        #expect(gap.path == "app.txt")

        let opened = await GitInspector.expand(gap, .up, root: repo.path)
        #expect(opened.lines.count == 36)
        #expect(opened.lines.contains { $0.text == " line 12" })
        #expect(!opened.lines.contains { $0.text == " line 12 changed" })
    }

    @Test func aHunkWithNothingAboveItGetsNoRow() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(10))
        try repo.commit("add app")
        try repo.write("app.txt", file(10, changing: 2))

        let diff = await diff(of: "app.txt", in: repo)
        // The change is at the top and the last five lines are all that is left over.
        let gaps = diff.lines.compactMap(\.gap)
        #expect(gaps.count == 1)
        #expect(gaps.first?.count == nil)
        #expect(diff.lines.first?.kind != .gap)
    }

    @Test func aFileShownWholeHasNothingLeftToOffer() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(10))
        try repo.commit("add app")
        // An added file is in the diff from its first line to its last, and a deleted
        // one has no new side to read at all.
        try repo.write("new.txt", file(8))
        try repo.git("add", "new.txt")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("app.txt"))

        let added = await diff(of: "new.txt", in: repo)
        #expect(added.lines.compactMap(\.gap).isEmpty)
        let deleted = await diff(of: "app.txt", in: repo)
        #expect(deleted.lines.compactMap(\.gap).isEmpty)
    }

    @Test func aFileThatIsGoneStopsAdvertisingItsLines() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let gap = try #require(diff.lines.compactMap(\.gap).first)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("app.txt"))

        let opened = await GitInspector.expand(gap, .up, root: repo.path)
        #expect(opened.lines.isEmpty)
        #expect(opened.gap == nil)
    }

    private func diff(of path: String, in repo: GitRepo) async -> FileDiff {
        let snapshot = await GitInspector.snapshot(at: repo.path)
        guard let change = snapshot.files.first(where: { $0.path == path }) else {
            Issue.record("\(path) is not in the snapshot: \(snapshot.files.map(\.path))")
            return FileDiff()
        }
        return await GitInspector.diff(for: change, root: repo.path)
    }
}
