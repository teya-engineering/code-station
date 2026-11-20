import Foundation
import Testing
@testable import MenuBarApp

// A file ticked off as read stays ticked while its content is the one read. The agent
// editing it again makes a new version, and the file asks to be read once more.
@MainActor
struct ViewedFilesTests {
    private let session = UUID()
    private let key = ViewedFileStore.key(root: "/repo", path: "Sources/App.swift")

    @Test func aVersionIsGitsOwnBlobID() {
        // `printf 'hello\n' | git hash-object --stdin` and `git hash-object /dev/null`.
        #expect(FileVersion.blobID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(FileVersion.blobID(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test func aTickLastsWhileTheContentDoes() {
        let store = ViewedFileStore(url: nil)
        #expect(store.state(key, version: "v1", in: session) == .notViewed)

        let read = Date(timeIntervalSince1970: 1_000)
        store.mark(key, version: "v1", in: session, at: read)
        #expect(store.state(key, version: "v1", in: session) == .viewed)
        #expect(store.state(key, version: "v2", in: session) == .edited(since: read))
        // Not yet read, so nothing can be said about it.
        #expect(store.state(key, version: nil, in: session) == .notViewed)
        // Another session has its own ticks.
        #expect(store.state(key, version: "v1", in: UUID()) == .notViewed)
    }

    @Test func readingANewVersionKeepsTheOlderOnesRead() {
        let store = ViewedFileStore(url: nil)
        store.mark(key, version: "v1", in: session)
        store.mark(key, version: "v2", in: session, at: Date(timeIntervalSince1970: 2_000))

        #expect(store.state(key, version: "v1", in: session) == .viewed)
        #expect(store.state(key, version: "v2", in: session) == .viewed)
        #expect(store.latest(key, in: session)?.version == "v2")

        store.unmark(key, version: "v2", in: session)
        #expect(store.state(key, version: "v2", in: session) == .edited(since: store.latest(key, in: session)!.at))
        store.unmark(key, version: "v1", in: session)
        #expect(store.state(key, version: "v1", in: session) == .notViewed)
        #expect(!store.hasMarks(session))
    }

    @Test func onlyTheNewestVersionsAreRemembered() {
        let store = ViewedFileStore(url: nil)
        for index in 0..<(ViewedFileStore.keptVersions + 3) { store.mark(key, version: "v\(index)", in: session) }

        #expect(store.marks(in: session)[key]?.count == ViewedFileStore.keptVersions)
        #expect(store.state(key, version: "v0", in: session) != .viewed)
        #expect(store.state(key, version: "v\(ViewedFileStore.keptVersions + 2)", in: session) == .viewed)
    }

    @Test func clearingCanBeTakenBack() {
        let store = ViewedFileStore(url: nil)
        store.mark(key, version: "v1", in: session)
        let cleared = store.marks(in: session)

        store.clear(session)
        #expect(store.state(key, version: "v1", in: session) == .notViewed)

        store.restore(cleared, in: session)
        #expect(store.state(key, version: "v1", in: session) == .viewed)
    }

    @Test func ticksAndTheirTextOutliveARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("review-comments.viewed.json")
        let text = "let ready = true\n"
        let version = FileVersion.blobID(Data(text.utf8))

        let store = ViewedFileStore(url: url)
        store.mark(key, version: version, text: text, in: session)
        #expect(store.flush())

        let reopened = ViewedFileStore(url: url)
        #expect(reopened.state(key, version: version, in: session) == .viewed)
        #expect(reopened.text(of: version) == text)

        // Once no tick names the version, its text goes too.
        reopened.remove(session)
        #expect(reopened.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ViewedFileStore(url: url).text(of: version) == nil)
    }

    @Test func textArrivingAfterTheTickWasTakenBackIsDropped() {
        let store = ViewedFileStore(url: nil)
        store.mark(key, version: "v1", in: session)
        store.unmark(key, version: "v1", in: session)

        store.keep("late", for: "v1")
        #expect(store.text(of: "v1") == nil)
    }

    @Test func theLinesAddedSinceAreFoundByContentNotPosition() {
        let viewed = "a\nb\nc"
        let current = "a\nx\nb\nc\ny"

        #expect(ViewedLines.added(since: viewed, in: current) == [2, 5])
        #expect(ViewedLines.added(since: current, in: current).isEmpty)
    }

    @Test func onlyAddedLinesOfTheDiffAreMarkedFresh() {
        let lines: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,3 +1,4 @@"),
            DiffLine(id: 1, kind: .context, text: " a"),
            DiffLine(id: 2, kind: .addition, text: "+x"),
            DiffLine(id: 3, kind: .context, text: " b"),
            DiffLine(id: 4, kind: .addition, text: "+y"),
        ]
        // Line 3 is new since it was read but unchanged against the last commit, so it
        // has no row of its own to mark.
        let keys = ViewedLines.freshKeys(added: [2, 3], in: lines)

        #expect(keys == [DiffComments.key(DiffAnchor(side: .new, line: 2))])
    }

    @Test func theLinesRemovedSinceAreTheOnesTheViewedTextStillHad() {
        let base = "a\nb\nc\nd"
        // b was already gone when the file was read; c went after.
        let viewed = "a\nc\nd"
        let current = "a\nd"

        #expect(ViewedLines.removed(since: viewed, in: current, base: base) == [3])
        #expect(ViewedLines.removed(since: current, in: current, base: base).isEmpty)
    }

    @Test func removedLinesOfTheDiffAreMarkedByTheirOldNumber() {
        let lines: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,4 +1,3 @@"),
            DiffLine(id: 1, kind: .context, text: " a"),
            DiffLine(id: 2, kind: .deletion, text: "-b"),
            DiffLine(id: 3, kind: .deletion, text: "-c"),
            DiffLine(id: 4, kind: .addition, text: "+x"),
            DiffLine(id: 5, kind: .context, text: " d"),
        ]
        let keys = ViewedLines.freshKeys(added: [2], removed: [3, 4], in: lines)

        // Old line 4 is d, which the diff keeps, so it has no removed row to mark.
        #expect(keys == [DiffComments.key(DiffAnchor(side: .new, line: 2)),
                         DiffComments.key(DiffAnchor(side: .old, line: 3))])
    }

    @Test func aCommitNamesTheBlobEachPathHoldsAfterIt() {
        let modified = String(repeating: "a", count: 40), after = String(repeating: "b", count: 40)
        let added = String(repeating: "c", count: 40), renamed = String(repeating: "d", count: 40)
        let zero = String(repeating: "0", count: 40)
        let raw = [
            ":100644 100644 \(modified) \(after) M", "Sources/App.swift",
            ":000000 100644 \(zero) \(added) A", "Sources/New.swift",
            ":100644 000000 \(modified) \(zero) D", "Sources/Gone.swift",
            ":100644 100644 \(modified) \(renamed) R090", "Sources/Old.swift", "Sources/Renamed.swift",
            "",
        ].joined(separator: "\0")

        #expect(GitInspector.parseRawVersions(raw) == [
            "Sources/App.swift": after,
            "Sources/New.swift": added,
            "Sources/Gone.swift": FileVersion.deleted,
            "Sources/Renamed.swift": renamed,
        ])
    }

    @Test func aFileOnDiskIsNamedByItsContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let files = [
            GitChange(path: "a.txt", kind: .modified, isStaged: false, isUnstaged: true, isBinary: false),
            GitChange(path: "gone.txt", kind: .deleted, isStaged: false, isUnstaged: true, isBinary: false),
        ]

        let versions = await FileVersion.onDisk(files, root: folder.path)

        #expect(versions == ["a.txt": "ce013625030ba8dba906f756967f9e9ca394464a", "gone.txt": FileVersion.deleted])
    }

    @Test func theTallySaysHowFarThroughTheReviewIs() {
        #expect(ViewedTally(viewed: 3, total: 7).label == "3 of 7 viewed")
        #expect(ViewedTally(viewed: 3, total: 7).footnote == "4 files not viewed yet")
        #expect(ViewedTally(viewed: 6, total: 7).footnote == "1 file not viewed yet")
        #expect(ViewedTally(viewed: 7, total: 7).label == "All 7 viewed")
        #expect(ViewedTally(viewed: 7, total: 7).footnote == "All 7 files viewed")
        // In History the footer counts the open commit's files.
        #expect(ViewedTally(viewed: 1, total: 3, inCommit: true).footnote == "2 files in this commit not viewed yet")
        #expect(ViewedTally(viewed: 3, total: 3, inCommit: true).footnote == "All 3 files in this commit viewed")
    }
}
