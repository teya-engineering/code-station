import Foundation
import Testing
@testable import MenuBarApp

struct CommitHistoryTests {
    @Test func readsAllFilesButOnlyTheSelectedPatch() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "hello\nagain\n")
        try repo.write("notes\t[1].txt", "fresh\n")
        try repo.commit("second")
        let hash = repo.head
        let status = try repo.git("status", "--porcelain")
        let result = await GitInspector.commitFiles(hash, root: repo.path)
        #expect(result.note == nil)
        #expect(result.parents.count == 1)
        #expect(result.files.count == 2)
        let file = try #require(result.files.first { $0.path == "notes\t[1].txt" })
        #expect(file.added == 1)
        #expect(file.removed == 0)
        #expect(file.kind == .added)
        let diff = await GitInspector.commitFileDiff(hash, parent: result.parents.first, file: file, root: repo.path)
        #expect(diff.note == nil)
        #expect(diff.lines.contains { $0.text == "+fresh" })
        #expect(!diff.lines.contains { $0.text == "+again" })
        #expect(try repo.git("status", "--porcelain") == status)
        #expect(repo.head == hash)
    }

    @Test func rootAndEmptyCommits() async throws {
        let repo = try GitRepo()
        let rootHash = repo.head
        let first = await GitInspector.commitFiles(rootHash, root: repo.path)
        #expect(first.note == nil)
        #expect(first.parents.isEmpty)
        let file = try #require(first.files.first)
        #expect(file.kind == .added)
        let diff = await GitInspector.commitFileDiff(rootHash, parent: nil, file: file, root: repo.path)
        #expect(diff.lines.contains { $0.text == "+hello" })
        try repo.git("commit", "--allow-empty", "-qm", "empty")
        let empty = await GitInspector.commitFiles(repo.head, root: repo.path)
        #expect(empty.note == nil)
        #expect(empty.files.isEmpty)
    }

    @Test func renamesDeletionsAndBinaryFiles() async throws {
        let repo = try GitRepo()
        try repo.write("remove.txt", "gone\n")
        try repo.commit("prepare")
        try repo.git("mv", "README.md", "MANUAL.md")
        try repo.git("rm", "remove.txt")
        try repo.write("image.bin", bytes: Data([0, 1, 2, 3]))
        try repo.commit("rename delete binary")
        let result = await GitInspector.commitFiles(repo.head, root: repo.path)
        let renamed = try #require(result.files.first { $0.path == "MANUAL.md" })
        #expect(renamed.originalPath == "README.md")
        #expect(renamed.kind == .renamed)
        let patch = await GitInspector.commitFileDiff(repo.head, parent: result.parents.first, file: renamed, root: repo.path)
        #expect(patch.lines.contains { $0.text == "rename from README.md" })
        #expect(result.files.first { $0.path == "remove.txt" }?.kind == .deleted)
        let binary = try #require(result.files.first { $0.path == "image.bin" })
        #expect(binary.isBinary)
        let preview = await GitInspector.commitFileDiff(repo.head, parent: result.parents.first, file: binary, root: repo.path)
        #expect(preview.note?.contains("image.bin") == true)
    }

    @Test func mergeComparesAgainstSelectedParent() async throws {
        let repo = try GitRepo()
        try repo.git("checkout", "-qb", "side")
        try repo.write("side.txt", "side\n")
        try repo.commit("side")
        let side = repo.head
        try repo.git("checkout", "-q", "main")
        try repo.write("main.txt", "main\n")
        try repo.commit("main")
        let main = repo.head
        try repo.git("merge", "--no-ff", "-qm", "merge", "side")
        let first = await GitInspector.commitFiles(repo.head, root: repo.path)
        #expect(first.parents == [main, side])
        #expect(first.files.map(\.path) == ["side.txt"])
        let second = await GitInspector.commitFiles(repo.head, parent: side, root: repo.path)
        #expect(second.files.map(\.path) == ["main.txt"])
        let file = try #require(second.files.first)
        let diff = await GitInspector.commitFileDiff(repo.head, parent: side, file: file, root: repo.path)
        #expect(diff.lines.contains { $0.text == "+main" })
    }

    @Test func invalidCommitReportsFailure() async throws {
        let repo = try GitRepo()
        let result = await GitInspector.commitFiles(String(repeating: "0", count: 40), root: repo.path)
        #expect(result.note != nil)
        #expect(result.files.isEmpty)
    }

    @MainActor @Test func selectingSameCommitKeepsFileAndParent() {
        let selection = CommitHistorySelection()
        let first = GitCommitSummary(hash: "first", shortHash: "first", author: "Test", relativeDate: "now", subject: "First")
        selection.select(first)
        selection.fileID = "notes.txt"
        selection.parent = "parent"
        selection.select(first)
        #expect(selection.fileID == "notes.txt")
        #expect(selection.parent == "parent")
        selection.select(GitCommitSummary(hash: "second", shortHash: "second", author: "Test", relativeDate: "now", subject: "Second"))
        #expect(selection.fileID == nil)
        #expect(selection.parent == nil)
    }

    @Test func recentCommitsCarryTheirDate() async throws {
        let repo = try GitRepo()
        let history = await GitInspector.recentCommits(at: repo.path)
        let commit = try #require(history.commits.first)
        let date = try #require(commit.date)
        #expect(abs(date.timeIntervalSinceNow) < 600)
    }

    @Test func filterMatchesSubjectWordsOrHashPrefix() {
        let commit = GitCommitSummary(hash: "cffbf35abc", shortHash: "cffbf35", author: "Test",
                                      relativeDate: "now", subject: "Pick the project from the navigator")
        #expect(commit.matches(""))
        #expect(commit.matches("PROJECT"))
        #expect(commit.matches("cffb"))
        #expect(commit.matches("CFFB"))
        #expect(!commit.matches("35abc"))
        #expect(!commit.matches("explorer"))
    }

    @Test func groupsCommitsUnderDayLabelsInGitOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        // A Thursday, so Monday to Wednesday are earlier this week.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15)))
        func commit(_ name: String, daysAgo: Int?) -> GitCommitSummary {
            GitCommitSummary(hash: name, shortHash: name, author: "Test", relativeDate: "", subject: name,
                             date: daysAgo.flatMap { calendar.date(byAdding: .day, value: -$0, to: now) })
        }
        let groups = CommitDay.groups([commit("a", daysAgo: 0), commit("b", daysAgo: 0),
                                       commit("c", daysAgo: 1), commit("d", daysAgo: 2),
                                       commit("e", daysAgo: 9), commit("f", daysAgo: 0),
                                       commit("g", daysAgo: nil)],
                                      now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Earlier this week", "Older", "Today", "Older"])
        #expect(groups.map { $0.commits.map(\.hash) } == [["a", "b"], ["c"], ["d"], ["e"], ["f"], ["g"]])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }
}
