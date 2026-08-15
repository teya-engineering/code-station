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
}
