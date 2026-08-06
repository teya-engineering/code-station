import Foundation
import Testing
@testable import MenuBarApp

// Editing goes through fullText and write rather than the preview, because the preview
// rewrites tabs and cuts long lines: saving it back would mangle the file. These pin
// down that the edit path keeps the bytes honest.
struct FileTreeTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fullTextKeepsTabsAndLongLines() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("raw.txt")
        let contents = "a\tb\n" + String(repeating: "x", count: 5000) + "\n"
        try Data(contents.utf8).write(to: file)

        #expect(await FileTree.fullText(of: file) == contents)
    }

    @Test func fullTextOfAnEmptyFileIsAnEmptyString() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        #expect(await FileTree.fullText(of: file) == "")
    }

    @Test func fullTextRefusesBinary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: file)

        #expect(await FileTree.fullText(of: file) == nil)
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
}
