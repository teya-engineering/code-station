import Foundation
import Testing
@testable import CodeStationCore
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

    @Test func binaryDetectionDoesNotDiscardInvalidTrailingBytes() {
        #expect(Data([0x61, 0xFF]).looksBinary)
        #expect(Data([0x61, 0xE2, 0x82]).looksBinary)
        #expect(!Data().looksBinary)
        #expect(!Data("hello🙂".utf8).looksBinary)
    }

    @Test func binaryDetectionCompletesACharacterAcrossTheSampleBoundary() {
        let text = String(repeating: "a", count: 7_999) + "🙂tail"
        #expect(!Data(text.utf8).looksBinary)
        var invalid = Data(repeating: 0x61, count: 7_999)
        invalid.append(contentsOf: [0xFF, 0x61, 0x61, 0x61])
        #expect(invalid.looksBinary)
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

    @Test func aLinkedFileIsReadThroughToItsTarget() async throws {
        let target = root.appendingPathComponent("AGENTS.md")
        let link = root.appendingPathComponent("CLAUDE.md")
        try Data("shared guidance".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "AGENTS.md")

        #expect(await FileTree.preview(of: link) == .text("shared guidance"))
    }

    // An atomic write renames a new file into place, so a save that forgot the link would
    // leave a copy behind and quietly split the two files apart.
    @Test func savingALinkedFileKeepsTheLink() async throws {
        let target = root.appendingPathComponent("AGENTS.md")
        let link = root.appendingPathComponent("CLAUDE.md")
        try Data("before".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "AGENTS.md")

        let failure = await FileTree.write("after", to: link)

        #expect(failure == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "after")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "AGENTS.md")
    }

    @Test func aBrokenLinkSaysWhereItPointed() async throws {
        let link = root.appendingPathComponent("CLAUDE.md")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "AGENTS.md")

        #expect(await FileTree.preview(of: link)
            == .unreadable("This link points at AGENTS.md, which is not there."))
    }

    @Test func linksListWithTheirTargetsSizeAndShape() async throws {
        let folder = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("shared guidance".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "AGENTS.md")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("guides").path, withDestinationPath: "docs")

        let nodes = await FileTree.children(of: root, includeHidden: false)
        let fileLink = try #require(nodes.first { $0.name == "CLAUDE.md" })
        let folderLink = try #require(nodes.first { $0.name == "guides" })

        #expect(fileLink.linkDestination == "AGENTS.md")
        #expect(!fileLink.isDirectory)
        #expect(fileLink.size == 15)
        #expect(folderLink.linkDestination == "docs")
        #expect(folderLink.isDirectory)
    }

    @Test func aLinkedFolderListsWhatItPointsAt() async throws {
        let folder = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("setup.md"))
        let link = root.appendingPathComponent("guides")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "docs")

        let nodes = await FileTree.children(of: link, includeHidden: false)

        #expect(nodes.map(\.name) == ["setup.md"])
    }

    // The tree opens one level at a time, but this walk reads everything, so a folder link
    // that points back up its own branch would never finish.
    @Test func theRecursiveWalkStopsAtLinkedFolders() async throws {
        let folder = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("setup.md"))
        try Data().write(to: root.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "AGENTS.md")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("loop").path, withDestinationPath: ".")

        let files = await FileTree.files(beneath: root, includeHidden: false)

        #expect(Set(files.map(\.name)) == ["AGENTS.md", "CLAUDE.md", "setup.md"])
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

    @Test func movesItemsToTheTrash() async throws {
        let file = root.appendingPathComponent("scratch.txt")
        try Data("bye".utf8).write(to: file)

        let trash = TestTrash()

        #expect(await FileTree.trash(file, using: trash.move) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(trash.moved == [file.lastPathComponent])
        #expect(await FileTree.trash(file, using: trash.move) != nil)
    }

    @Test func renamesAnItemInItsFolder() async throws {
        let file = root.appendingPathComponent("draft.txt")
        try Data("hi".utf8).write(to: file)

        let result = await FileTree.rename(file, to: " final.txt ")

        #expect(result == .renamed(root.appendingPathComponent("final.txt")))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: root.appendingPathComponent("final.txt"),
                           encoding: .utf8) == "hi")
    }

    @Test func renamesWhenOnlyTheCaseChanges() async throws {
        let file = root.appendingPathComponent("readme.md")
        try Data("hi".utf8).write(to: file)

        let result = await FileTree.rename(file, to: "README.md")

        #expect(result == .renamed(root.appendingPathComponent("README.md")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["README.md"])
    }

    @Test func refusesNamesThatWouldLoseOrMoveSomething() async throws {
        let file = root.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))

        #expect(await FileTree.rename(file, to: "a.txt") == .unchanged)
        for name in ["b.txt", "", "  ", "..", "sub/a.txt"] {
            guard case .failed = await FileTree.rename(file, to: name) else {
                Issue.record("\(name) was accepted")
                continue
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "a")
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "b")
    }

    @Test func pathsInsideARenamedFolderFollowIt() {
        #expect(FileTree.path("/p/src", afterMoving: "/p/src", to: "/p/lib") == "/p/lib")
        #expect(FileTree.path("/p/src/a/b.swift", afterMoving: "/p/src", to: "/p/lib")
                == "/p/lib/a/b.swift")
        #expect(FileTree.path("/p/srcs/b.swift", afterMoving: "/p/src", to: "/p/lib")
                == "/p/srcs/b.swift")
    }

    @Test func createsUntitledItemsWithoutTakingANameInUse() async throws {
        try Data("keep".utf8).write(to: root.appendingPathComponent("untitled"))

        let file = await FileTree.create(folder: false, in: root)
        let folder = await FileTree.create(folder: true, in: root)
        let second = await FileTree.create(folder: true, in: root)

        #expect(file == .created(root.appendingPathComponent("untitled 2")))
        #expect(folder == .created(root.appendingPathComponent("untitled folder", isDirectory: true)))
        #expect(second == .created(root.appendingPathComponent("untitled folder 2", isDirectory: true)))
        #expect(try String(contentsOf: root.appendingPathComponent("untitled"), encoding: .utf8) == "keep")
        #expect(await FileTree.preview(of: root.appendingPathComponent("untitled 2")) == .empty)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("untitled folder 2").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func reportsWhenTheFolderIsGone() async {
        let result = await FileTree.create(folder: false, in: root.appendingPathComponent("missing"))

        guard case .failed = result else {
            Issue.record("created \(result)")
            return
        }
    }

    @Test func movesItemsIntoAFolder() async throws {
        let file = root.appendingPathComponent("notes.txt")
        let folder = root.appendingPathComponent("Guide")
        let destination = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: file)
        try Data("g".utf8).write(to: folder.appendingPathComponent("README.md"))

        let result = await FileTree.move([file, folder], into: destination)

        #expect(result.failures.isEmpty)
        #expect(result.moved.map(\.to.lastPathComponent) == ["notes.txt", "Guide"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: destination.appendingPathComponent("Guide/README.md"),
                           encoding: .utf8) == "g")
    }

    @Test func aMoveNeverReplacesWhatIsThere() async throws {
        let file = root.appendingPathComponent("notes.txt")
        let destination = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: file)
        try Data("old".utf8).write(to: destination.appendingPathComponent("notes.txt"))

        let result = await FileTree.move([file], into: destination)

        #expect(result.moved.isEmpty)
        #expect(result.failures.map(\.name) == ["notes.txt"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"),
                           encoding: .utf8) == "old")
    }

    @Test func droppingWhereAnItemStartedDoesNothing() async throws {
        let folder = root.appendingPathComponent("src")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let inPlace = await FileTree.move([folder], into: root)
        let ontoItself = await FileTree.move([folder], into: folder)
        let intoItsChild = await FileTree.move([folder], into: nested)

        #expect(inPlace == FileTree.MoveResult())
        #expect(ontoItself == FileTree.MoveResult())
        #expect(intoItsChild.moved.isEmpty)
        #expect(intoItsChild.failures.map(\.name) == ["src"])
        #expect(FileManager.default.fileExists(atPath: nested.path))
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
