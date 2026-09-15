import Foundation
import Testing
@testable import MenuBarApp

// A diff only shows a few lines around each change. The hunk headers stand for the rest,
// and pressing one has to bring those lines back from the version the diff was made
// against: the file on disk, the staged copy, or the file as a commit left it.
struct GitDiffExpandTests {

    private func file(_ count: Int, changing line: Int? = nil) -> String {
        (1...count).map { number in
            number == line ? "line \(number) changed" : "line \(number)"
        }.joined(separator: "\n") + "\n"
    }

    @Test func aHeaderKnowsHowManyLinesItHides() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        // Three lines of context put the hunk at line 37, so lines 1 to 36 are hidden.
        #expect(hunk.hiddenStart == 1)
        #expect(hunk.hidden == 36)
        #expect(hunk.revision == .workingTree)
        #expect(hunk.path == "app.txt")
    }

    @Test func aShortGapOpensInOneGo() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        let opened = await GitInspector.expand(hunk, root: repo.path)

        #expect(opened.hunk == nil)
        #expect(opened.lines.count == 36)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.last?.text == " line 36")
        #expect(opened.lines.allSatisfy { $0.kind == .context })
    }

    @Test func aLongGapOpensAStepAtATime() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        try repo.write("app.txt", file(200, changing: 150))

        let diff = await diff(of: "app.txt", in: repo)
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        #expect(hunk.hidden == 146)

        // The lines nearest the change come back first, and the header keeps the rest.
        let opened = await GitInspector.expand(hunk, root: repo.path)
        #expect(opened.lines.count == 20)
        #expect(opened.lines.first?.text == " line 127")
        #expect(opened.lines.last?.text == " line 146")
        #expect(opened.hunk?.hidden == 126)
        #expect(opened.hunk?.hiddenStart == 1)
        // The header keeps its name while it shrinks, so the pane can find the row again.
        #expect(opened.hunk?.key == hunk.key)
    }

    @Test func theSecondHeaderStartsWhereTheFirstHunkEnded() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(200))
        try repo.commit("add app")
        var lines = (1...200).map { "line \($0)" }
        lines[9] = "line 10 changed"
        lines[99] = "line 100 changed"
        try repo.write("app.txt", lines.joined(separator: "\n") + "\n")

        let diff = await diff(of: "app.txt", in: repo)
        let hunks = diff.lines.compactMap(\.hunk)
        #expect(hunks.count == 2)
        // The first hunk covers lines 7 to 13, so the second one hides everything from 14.
        #expect(hunks[1].hiddenStart == 14)
        #expect(hunks[1].hidden == 83)

        let opened = await GitInspector.expand(hunks[1], root: repo.path)
        #expect(opened.lines.first?.text == " line 77")
        #expect(opened.lines.last?.text == " line 96")
    }

    @Test func aStagedHunkReadsTheStagedCopy() async throws {
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
        let staged = try #require(diff.lines.compactMap(\.hunk).first { $0.revision == .index })
        let opened = await GitInspector.expand(staged, root: repo.path)
        #expect(opened.lines.first?.text == " line 1")
        #expect(opened.lines.contains { $0.text == " line 5" })
        #expect(!opened.lines.contains { $0.text == " line 5 later" })
    }

    @Test func aCommitHunkReadsThatCommit() async throws {
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
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        #expect(hunk.revision == .commit(hash))
        #expect(hunk.path == "app.txt")

        let opened = await GitInspector.expand(hunk, root: repo.path)
        #expect(opened.lines.count == 36)
        #expect(opened.lines.contains { $0.text == " line 12" })
        #expect(!opened.lines.contains { $0.text == " line 12 changed" })
    }

    @Test func aHeaderWithNothingAboveItCannotBeOpened() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(10))
        try repo.commit("add app")
        try repo.write("app.txt", file(10, changing: 2))

        let diff = await diff(of: "app.txt", in: repo)
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        #expect(hunk.hidden == 0)
        #expect(!hunk.isExpandable)

        let opened = await GitInspector.expand(hunk, root: repo.path)
        #expect(opened.lines.isEmpty)
        #expect(opened.hunk == nil)
    }

    @Test func aFileThatIsGoneStopsAdvertisingItsLines() async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", file(60))
        try repo.commit("add app")
        try repo.write("app.txt", file(60, changing: 40))

        let diff = await diff(of: "app.txt", in: repo)
        let hunk = try #require(diff.lines.compactMap(\.hunk).first)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("app.txt"))

        let opened = await GitInspector.expand(hunk, root: repo.path)
        #expect(opened.lines.isEmpty)
        #expect(opened.hunk == nil)
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
