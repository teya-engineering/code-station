import Foundation
import Testing
@testable import MenuBarApp

// The pane a file lands in can be typed into and saved back, so what comes out of the
// preview has to be the bytes that are on disk. These pin down that nothing is rewritten
// on the way in or out.
struct FileTreeTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("raw.txt")
        let contents = "a\tb\n" + String(repeating: "x", count: 5000) + "\n"
        try Data(contents.utf8).write(to: file)

        #expect(await FileTree.preview(of: file) == .text(contents))
    }

    @Test func textKeepsEveryLineOfALongFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.txt")
        let contents = (1...9000).map { "line \($0)" }.joined(separator: "\n")
        try Data(contents.utf8).write(to: file)

        #expect(await FileTree.preview(of: file) == .text(contents))
    }

    @Test func anEmptyFileIsNotText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        #expect(await FileTree.preview(of: file) == .empty)
    }

    @Test func binaryIsRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: file)

        #expect(await FileTree.preview(of: file) == .binary(size: 4))
    }

    @Test func writeRoundTrips() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("before".utf8).write(to: file)

        let failure = await FileTree.write("after\tstill tabbed\n", to: file)

        #expect(failure == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after\tstill tabbed\n")
    }

    @Test func writeReportsWhatWentWrong() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-folder/notes.md")

        let failure = await FileTree.write("text", to: missing)

        #expect(failure != nil)
    }

    @Test func listsFilesRecursivelyWithoutWalkingGitMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
}
