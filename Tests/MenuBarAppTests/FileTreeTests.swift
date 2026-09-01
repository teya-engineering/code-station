import Foundation
import Testing
@testable import MenuBarApp

// The pane a file lands in can be typed into and saved back, so what comes out of the
// preview has to be the bytes that are on disk. These pin down that nothing is rewritten
// on the way in or out.
struct FileTreeTests {
    private let scratch = ScratchDirectory(prefix: "filetree-tests")
    private var root: URL { scratch.url }

    @Test func offersRenderedPreviewForMarkdownFiles() {
        let markdown = FileNode(url: URL(fileURLWithPath: "/project/README.MD"),
                                name: "README.MD", isDirectory: false, size: 0)
        let longExtension = FileNode(url: URL(fileURLWithPath: "/project/guide.markdown"),
                                     name: "guide.markdown", isDirectory: false, size: 0)
        let text = FileNode(url: URL(fileURLWithPath: "/project/notes.txt"),
                            name: "notes.txt", isDirectory: false, size: 0)

        #expect(markdown.supportsMarkdownPreview)
        #expect(longExtension.supportsMarkdownPreview)
        #expect(!text.supportsMarkdownPreview)
    }

    @Test func textKeepsTabsAndLongLines() async throws {
        let file = root.appendingPathComponent("raw.txt")
        let contents = "a\tb\n" + String(repeating: "x", count: 5000) + "\n"
        try Data(contents.utf8).write(to: file)

        #expect(await FileTree.preview(of: file) == .text(contents))
    }

    @Test func textKeepsEveryLineOfALongFile() async throws {
        let file = root.appendingPathComponent("long.txt")
        let contents = (1...9000).map { "line \($0)" }.joined(separator: "\n")
        try Data(contents.utf8).write(to: file)

        #expect(await FileTree.preview(of: file) == .text(contents))
    }

    @Test func anEmptyFileIsNotText() async throws {
        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        #expect(await FileTree.preview(of: file) == .empty)
    }

    @Test func binaryIsRefused() async throws {
        let file = root.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: file)

        #expect(await FileTree.preview(of: file) == .binary(size: 4))
    }

    @Test func writeRoundTrips() async throws {
        let file = root.appendingPathComponent("notes.md")
        try Data("before".utf8).write(to: file)

        let failure = await FileTree.write("after\tstill tabbed\n", to: file)

        #expect(failure == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after\tstill tabbed\n")
    }

    @Test func writeReportsWhatWentWrong() async throws {
        let missing = root.appendingPathComponent("no-such-folder/notes.md")

        let failure = await FileTree.write("text", to: missing)

        #expect(failure != nil)
    }

    @Test func listsFilesRecursivelyWithoutWalkingGitMetadata() async throws {
        let nested = root.appendingPathComponent("Sources/Feature")
        let git = root.appendingPathComponent(".git/objects")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("View.swift"))
        try Data().write(to: root.appendingPathComponent(".env"))
        try Data().write(to: git.appendingPathComponent("object"))

        let visible = await FileTree.files(beneath: root, includeHidden: false)
        let withHidden = await FileTree.files(beneath: root, includeHidden: true)

        #expect(visible.map(\.name) == ["View.swift"])
        #expect(Set(withHidden.map(\.name)) == [".env", "View.swift"])
    }

    @Test func givesAncestorDirectoriesFromRootToFile() {
        let root = URL(fileURLWithPath: "/project")
        let file = URL(fileURLWithPath: "/project/Sources/Feature/View.swift")

        #expect(FileTree.ancestorDirectories(of: file, beneath: root) == [
            "/project/Sources", "/project/Sources/Feature"
        ])
        #expect(FileTree.ancestorDirectories(
            of: URL(fileURLWithPath: "/elsewhere/View.swift"), beneath: root).isEmpty)
    }

    @Test func copiesFilesAndFolders() async throws {
        let sourceFolder = root.appendingPathComponent("source/Guide")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: sourceFolder.appendingPathComponent("README.md"))

        let result = await FileTree.copy([sourceFolder], into: destination)

        #expect(result.failures.isEmpty)
        #expect(result.copied.map(\.lastPathComponent) == ["Guide"])
        #expect(try String(contentsOf: destination.appendingPathComponent("Guide/README.md"),
                           encoding: .utf8) == "hello")
    }

    @Test func keepsExistingItemsWhenCopyNamesCollide() async throws {
        let source = root.appendingPathComponent("source/notes.txt")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try Data("first".utf8).write(to: destination.appendingPathComponent("notes.txt"))
        try Data("second".utf8).write(to: destination.appendingPathComponent("notes copy.txt"))

        let result = await FileTree.copy([source], into: destination)

        #expect(result.failures.isEmpty)
        #expect(result.copied.map(\.lastPathComponent) == ["notes copy 2.txt"])
        #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"),
                           encoding: .utf8) == "first")
        #expect(try String(contentsOf: destination.appendingPathComponent("notes copy 2.txt"),
                           encoding: .utf8) == "new")
    }

    @Test func refusesToCopyAFolderInsideItself() async throws {
        let source = root.appendingPathComponent("source")
        let destination = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = await FileTree.copy([source], into: destination)

        #expect(result.copied.isEmpty)
        #expect(result.failures.map(\.name) == ["source"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("source").path))
    }

    @Test func movesUpAndDownThroughVisibleRows() {
        let rows = navigationRows()

        #expect(FileTreeNavigation.action(
            for: .down, selectedPath: "/project/Sources", rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/Sources/App.swift"))
        #expect(FileTreeNavigation.action(
            for: .up, selectedPath: "/project/README.md", rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/Sources/App.swift"))
        #expect(FileTreeNavigation.action(
            for: .up, selectedPath: "/project/Sources", rows: rows,
            expanded: ["/project/Sources"]) == nil)
    }

    @Test func rightOpensFoldersThenMovesToTheirFirstChild() {
        let rows = navigationRows()

        #expect(FileTreeNavigation.action(
            for: .right, selectedPath: "/project/Sources", rows: rows,
            expanded: []) == .expand("/project/Sources"))
        #expect(FileTreeNavigation.action(
            for: .right, selectedPath: "/project/Sources", rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/Sources/App.swift"))
        #expect(FileTreeNavigation.action(
            for: .right, selectedPath: "/project/README.md", rows: rows,
            expanded: ["/project/Sources"]) == nil)
    }

    @Test func leftClosesFoldersOrMovesToTheirParent() {
        let rows = navigationRows()

        #expect(FileTreeNavigation.action(
            for: .left, selectedPath: "/project/Sources", rows: rows,
            expanded: ["/project/Sources"]) == .collapse("/project/Sources"))
        #expect(FileTreeNavigation.action(
            for: .left, selectedPath: "/project/Sources/App.swift", rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/Sources"))
        #expect(FileTreeNavigation.action(
            for: .left, selectedPath: "/project/README.md", rows: rows,
            expanded: ["/project/Sources"]) == nil)
    }

    @Test func startsAtTheNearestEndWhenNothingIsSelected() {
        let rows = navigationRows()

        #expect(FileTreeNavigation.action(
            for: .down, selectedPath: nil, rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/Sources"))
        #expect(FileTreeNavigation.action(
            for: .up, selectedPath: nil, rows: rows,
            expanded: ["/project/Sources"]) == .select("/project/README.md"))
    }

    private func navigationRows() -> [FileTreeNavigation.Row] {
        [
            .init(path: "/project/Sources", isDirectory: true, depth: 0),
            .init(path: "/project/Sources/App.swift", isDirectory: false, depth: 1),
            .init(path: "/project/README.md", isDirectory: false, depth: 0)
        ]
    }
}
