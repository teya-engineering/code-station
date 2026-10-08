import Foundation
import Testing
@testable import MenuBarApp

struct FindInFilesTests {

    @Test func listsEachMatchingLineOnceWithEveryHitMarked() {
        let text = "import Foundation\n    let monitor = WindowKeyMonitor(.control, \"h\") // windowkeymonitor\nnothing\n"

        let found = FileTextSearch.lines(matching: "WindowKeyMonitor", in: text)

        #expect(found.lines == [FileTextLine(
            number: 2,
            text: "let monitor = WindowKeyMonitor(.control, \"h\") // windowkeymonitor",
            hits: [NSRange(location: 14, length: 16), NSRange(location: 49, length: 16)])])
        #expect(found.next == nil)
    }

    @Test func numbersLinesFromOneAndCountsBlankLines() {
        let found = FileTextSearch.lines(matching: "x", in: "x\n\n\r\n\tx\r\n")

        #expect(found.lines.map(\.number) == [1, 4])
        #expect(found.lines.map(\.text) == ["x", "x"])
    }

    @Test func cutsALongLineDownToThePartAroundTheFirstHit() {
        let line = String(repeating: "a", count: 1_000) + "needle" + String(repeating: "b", count: 1_000)

        let found = FileTextSearch.lines(matching: "needle", in: line).lines[0]
        let text = found.text as NSString

        #expect(text.length <= FileTextSearch.excerptLength + 2)
        #expect(found.text.hasPrefix("…"))
        #expect(found.text.hasSuffix("…"))
        #expect(found.hits.count == 1)
        #expect(text.substring(with: found.hits[0]) == "needle")
    }

    @Test func groupsMatchesByFileAndSkipsFilesWithout() {
        let documents = [
            document("/project/A.swift", "let a = 1\nlet b = a"),
            document("/project/B.swift", "nothing here"),
            document("/project/C.swift", "LET c")
        ]

        let result = FileTextSearch.matches("let", in: documents)

        #expect(result.files.map(\.file.name) == ["A.swift", "C.swift"])
        #expect(result.files.map { $0.lines.map(\.number) } == [[1, 2], [1]])
        #expect(result.lineCount == 3)
        #expect(result.summary == "3 matches in 2 files")
    }

    @Test func usesSingularWordsForOne() {
        let result = FileTextSearch.matches("only", in: [document("/project/A.swift", "only")])

        #expect(result.summary == "1 match in 1 file")
    }

    @Test func blankQueriesHaveNoMatches() {
        let result = FileTextSearch.matches("  ", in: [document("/project/A.swift", "  ")])

        #expect(result == FileTextSearchResult())
    }

    @Test func stopsAfterAPageAndSaysWhereTheNextOneStarts() {
        let text = Array(repeating: "hit", count: FileTextSearch.pageSize).joined(separator: "\n")
        let documents = [document("/project/A.txt", text), document("/project/B.txt", "no\nhit")]

        let result = FileTextSearch.matches("hit", in: documents)

        #expect(result.lineCount == FileTextSearch.pageSize)
        #expect(result.files.count == 1)
        #expect(result.next == FileTextSearchCursor(document: 1, location: 3))
        #expect(result.summary == "\(FileTextSearch.pageSize)+ matches in 1+ file")
    }

    @Test func endsWithoutANextPageWhenTheLastMatchFillsThePage() {
        let text = Array(repeating: "hit", count: FileTextSearch.pageSize).joined(separator: "\n")

        let result = FileTextSearch.matches("hit", in: [document("/project/A.txt", text),
                                                       document("/project/B.txt", "nothing")])

        #expect(result.lineCount == FileTextSearch.pageSize)
        #expect(!result.hasMore)
    }

    @Test func pagesTogetherListEveryLineOnceAndKeepACutFileInOneGroup() {
        let documents = [
            document("/project/A.txt", "a1\nx\na2\na3 a\na4"),
            document("/project/B.txt", "a5")
        ]

        var result = FileTextSearch.matches("a", in: documents, limit: 2)
        #expect(result.lineCount == 2)
        while let next = result.next {
            result.append(FileTextSearch.matches("a", in: documents, from: next, limit: 2))
        }

        #expect(result.files.map(\.file.name) == ["A.txt", "B.txt"])
        #expect(result.files.map { $0.lines.map(\.text) } == [["a1", "a2", "a3 a", "a4"], ["a5"]])
        #expect(result.files[0].lines[2].hits.count == 2)
        #expect(result.summary == "5 matches in 2 files")
    }

    @Test func aFileWithManyHitsDoesNotEndTheSearch() {
        let text = String(repeating: "a", count: 20_000)
        let documents = [document("/project/A.txt", text), document("/project/B.txt", "a")]

        let result = FileTextSearch.matches("a", in: documents)

        #expect(result.files.map(\.file.name) == ["A.txt", "B.txt"])
        #expect(!result.hasMore)
    }

    @Test func marksHitsOnOneLineAsRangesIntoTheWholeText() {
        let text = "first find\nsecond FIND and find\nthird find"

        let hits = FileTextSearch.hits(of: "find", onLine: 2, in: text)

        #expect(hits == [NSRange(location: 18, length: 4), NSRange(location: 27, length: 4)])
        #expect(FileTextSearch.hits(of: "find", onLine: 9, in: text).isEmpty)
    }

    @Test func readsOnlyFilesTheEditorCouldShow() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindInFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("let text = 1".utf8).write(to: folder.appendingPathComponent("Text.swift"))
        try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("Data.bin"))
        try Data("<svg>text</svg>".utf8).write(to: folder.appendingPathComponent("Icon.svg"))
        try Data().write(to: folder.appendingPathComponent("Empty.txt"))

        let files = await FileTree.files(beneath: folder, includeHidden: true)
        let documents = await FileTextSearch.documents(for: files)

        #expect(documents.map(\.file.name) == ["Text.swift"])
        #expect(documents.first?.text == "let text = 1")
    }

    private func document(_ path: String, _ text: String) -> FileTextDocument {
        let url = URL(fileURLWithPath: path)
        return FileTextDocument(
            file: FileNode(url: url, name: url.lastPathComponent, isDirectory: false,
                           size: Int64(text.utf8.count), modified: nil),
            text: text)
    }
}
