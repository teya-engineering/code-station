import Foundation
import Testing
@testable import MenuBarApp

// Prose images render inline only when they point at a real local file; everything
// else must fall back to the text that was written.
struct MarkdownImageTests {

    // MARK: - Parsing

    @Test func readsAnImageOnItsOwn() {
        #expect(MarkdownBlock.paragraphParts("![shot](/tmp/shot.png)") ==
            [.image(alt: "shot", source: "/tmp/shot.png")])
    }

    @Test func readsAnImageWithAnEmptyAlt() {
        #expect(MarkdownBlock.paragraphParts("![](out.png)") ==
            [.image(alt: "", source: "out.png")])
    }

    @Test func readsImagesMixedIntoAParagraph() {
        let parts = MarkdownBlock.paragraphParts(
            "Before ![one](a.png) between ![two](b.png) after")
        #expect(parts == [
            .text("Before "),
            .image(alt: "one", source: "a.png"),
            .text(" between "),
            .image(alt: "two", source: "b.png"),
            .text(" after"),
        ])
    }

    @Test func leavesTextWithoutImagesAlone() {
        #expect(MarkdownBlock.paragraphParts("plain words") == [.text("plain words")])
    }

    @Test func leavesBadSyntaxAsText() {
        #expect(MarkdownBlock.paragraphParts("a ![broken(x.png) b") ==
            [.text("a ![broken(x.png) b")])
        #expect(MarkdownBlock.paragraphParts("a ![no paren] b") ==
            [.text("a ![no paren] b")])
        #expect(MarkdownBlock.paragraphParts("a ![alt](unclosed b") ==
            [.text("a ![alt](unclosed b")])
        #expect(MarkdownBlock.paragraphParts("a ![alt]() b") ==
            [.text("a ![alt]() b")])
    }

    @Test func aBangBracketDoesNotSwallowALaterImage() {
        #expect(MarkdownBlock.paragraphParts("![oops ![ok](a.png)") == [
            .text("![oops "),
            .image(alt: "ok", source: "a.png"),
        ])
    }

    @Test func anImageDoesNotSpanLines() {
        let text = "![alt\n](a.png)"
        #expect(MarkdownBlock.paragraphParts(text) == [.text(text)])
    }

    // MARK: - Putting unresolved images back

    @Test func splitsAroundAnImageThatResolves() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let parts = MarkdownBlock.resolvedParts("See ![shot](a.png) here") { _ in url }
        #expect(parts == [
            .text("See "),
            .image(alt: "shot", url: url),
            .text(" here"),
        ])
    }

    @Test func putsAnUnresolvedImageBackAsWritten() {
        let text = "See ![shot](https://example.com/a.png) here"
        let parts = MarkdownBlock.resolvedParts(text) { _ in nil }
        #expect(parts == [.text(text)])
    }

    @Test func mergesTextAroundAnUnresolvedImageBetweenResolvedOnes() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let parts = MarkdownBlock.resolvedParts("![one](a.png) and ![two](gone.png)!") {
            $0 == "a.png" ? url : nil
        }
        #expect(parts == [
            .image(alt: "one", url: url),
            .text(" and ![two](gone.png)!"),
        ])
    }

    // MARK: - Path resolution

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func resolvesAnAbsolutePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shot.png")
        try Data().write(to: file)

        #expect(TranscriptImage.resolve(file.path, projectPath: "/somewhere/else")?.path
            == file.path)
    }

    @Test func resolvesAPathRelativeToTheProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("shot.jpeg"))

        let resolved = TranscriptImage.resolve("docs/shot.jpeg", projectPath: root.path)
        #expect(resolved?.path == folder.appendingPathComponent("shot.jpeg").path)
    }

    @Test func rejectsAMissingFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(TranscriptImage.resolve("gone.png", projectPath: root.path) == nil)
        #expect(TranscriptImage.resolve(root.appendingPathComponent("gone.png").path,
                                        projectPath: root.path) == nil)
    }

    @Test func rejectsANonImageExtension() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        try Data().write(to: root.appendingPathComponent("plain"))

        #expect(TranscriptImage.resolve("notes.txt", projectPath: root.path) == nil)
        #expect(TranscriptImage.resolve("plain", projectPath: root.path) == nil)
    }

    @Test func rejectsARemoteURL() {
        #expect(TranscriptImage.resolve("https://example.com/a.png", projectPath: "/tmp") == nil)
        #expect(TranscriptImage.resolve("http://example.com/a.png", projectPath: "/tmp") == nil)
    }

    @Test func rejectsADirectoryEvenWithAnImageName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("odd.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(TranscriptImage.resolve("odd.png", projectPath: root.path) == nil)
    }
}
