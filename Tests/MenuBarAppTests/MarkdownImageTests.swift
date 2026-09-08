import Foundation
import Testing
@testable import MenuBarApp

// Prose images render inline only when they point at a real local file; everything
// else must fall back to the text that was written.
struct MarkdownImageTests {
    private let scratch = ScratchDirectory(prefix: "markdown-image-tests")
    private var root: URL { scratch.url }

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

    @Test func rendersTheLinkedDesktopAndMobilePreviews() throws {
        let desktop = root.appendingPathComponent("desktop.png")
        let mobile = root.appendingPathComponent("mobile.jpg")
        try Data().write(to: desktop)
        try Data().write(to: mobile)

        let parts = MarkdownBlock.resolvedParts(
            "[Desktop preview](\(desktop.path)) · [Mobile preview](mobile.jpg)") {
                TranscriptImage.resolve($0, projectPath: root.path)
            }
        #expect(parts == [
            .image(alt: "Desktop preview", url: desktop),
            .text(" · "),
            .image(alt: "Mobile preview", url: mobile),
        ])
    }

    @Test(arguments: ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "PNG"])
    func rendersLinksToImageFormats(_ extensionName: String) throws {
        let file = root.appendingPathComponent("preview.\(extensionName)")
        try Data().write(to: file)

        let parts = MarkdownBlock.resolvedParts("[Preview](\(file.absoluteString))") {
            TranscriptImage.resolve($0, projectPath: root.path)
        }
        #expect(parts == [.image(alt: "Preview", url: file)])
    }

    @Test func handlesSpacesParenthesesAndLinkTitles() throws {
        let file = root.appendingPathComponent("desktop preview (wide).png")
        try Data().write(to: file)

        for source in ["<\(file.path)> \"Desktop\"", file.absoluteString,
                       "desktop%20preview%20(wide).png"] {
            let parts = MarkdownBlock.resolvedParts("[**Desktop** preview](\(source))") {
                TranscriptImage.resolve($0, projectPath: root.path)
            }
            #expect(parts == [.image(alt: "Desktop preview", url: file)])
        }
    }

    @Test func keepsOtherLinksAndSurroundingFormatting() throws {
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let text = "**Files:** [Notes](notes.txt), [Missing](gone.png), "
            + "[Web](https://example.com/shot.png) and `code`."

        #expect(MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: root.path)
        } == [.text(text)])
    }

    @Test(arguments: ["`[Preview](shot.png)`", "`` `[Preview](shot.png)` ``",
                      "`![Preview](shot.png)`", #"\[Preview](shot.png)"#,
                      "[Preview](unclosed.png", "[Preview]", "[Preview]()"])
    func leavesCodeEscapesAndIncompleteLinksAlone(_ text: String) {
        #expect(MarkdownBlock.paragraphParts(text) == [.text(text)])
    }

    @Test func rendersALinkAfterInlineCode() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        #expect(MarkdownBlock.resolvedParts("`[Example](shot.png)` [Preview](shot.png)") { _ in url } == [
            .text("`[Example](shot.png)` "),
            .image(alt: "Preview", url: url),
        ])
    }

    // MARK: - Path resolution

    @Test func resolvesAnAbsolutePath() throws {
        let file = root.appendingPathComponent("shot.png")
        try Data().write(to: file)

        #expect(TranscriptImage.resolve(file.path, projectPath: "/somewhere/else")?.path
            == file.path)
    }

    @Test func resolvesAPathRelativeToTheProject() throws {
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("shot.jpeg"))

        let resolved = TranscriptImage.resolve("docs/shot.jpeg", projectPath: root.path)
        #expect(resolved?.path == folder.appendingPathComponent("shot.jpeg").path)
    }

    @Test func resolvesFileURLsAndEncodedPaths() throws {
        let file = root.appendingPathComponent("a preview.png")
        try Data().write(to: file)

        for source in [file.absoluteString, "a%20preview.png", "<\(file.path)>"] {
            #expect(TranscriptImage.resolve(source, projectPath: root.path)?.path == file.path)
        }
    }

    @Test func preservesSpecialCharactersInImagePaths() throws {
        let file = root.appendingPathComponent("preview #1?.png")
        try Data().write(to: file)

        #expect(TranscriptImage.resolve(file.path, projectPath: root.path)?.path == file.path)
        #expect(TranscriptImage.resolve(file.absoluteString, projectPath: root.path)?.path == file.path)
    }

    @Test func rejectsNonLocalSchemesAndHosts() {
        for source in ["//example.com/shot.png", "file://example.com/shot.png",
                       "data:image/png;base64,abc", "ftp://example.com/shot.png"] {
            #expect(TranscriptImage.resolve(source, projectPath: root.path) == nil)
        }
    }

    @Test func rejectsAMissingFile() throws {
        #expect(TranscriptImage.resolve("gone.png", projectPath: root.path) == nil)
        #expect(TranscriptImage.resolve(root.appendingPathComponent("gone.png").path,
                                        projectPath: root.path) == nil)
    }

    @Test func rejectsANonImageExtension() throws {
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
        let folder = root.appendingPathComponent("odd.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(TranscriptImage.resolve("odd.png", projectPath: root.path) == nil)
    }
}
