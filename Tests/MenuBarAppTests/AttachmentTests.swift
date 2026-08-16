import AppKit
import Foundation
import Testing
@testable import MenuBarApp

// Attachments are the one part of a prompt the user cannot see before it is sent: what
// reaches the CLI is a path, and a wrong one fails silently as a file the agent cannot
// read. These pin down what the clipboard turns into and what the CLI is told about it.
struct AttachmentTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - What the clipboard gives back

    @Test func takesFilesFromTheClipboard() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        let found = Attachments.fromClipboard(pasteboard)
        #expect(found.map(\.url.lastPathComponent) == ["notes.txt"])
    }

    // Copying a file in Finder puts its name on the clipboard as text too, and the file
    // is what was meant.
    @Test func prefersTheFileOverTheTextThatComesWithIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shot.png")
        try pngData().write(to: file)

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("shot.png", forType: .string)

        let found = Attachments.fromClipboard(pasteboard)
        #expect(found.count == 1)
        #expect(found.first?.url == file)
    }

    @Test func writesAPastedImageToDisk() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)

        let found = Attachments.fromClipboard(pasteboard)
        let attachment = try #require(found.first)
        defer { try? FileManager.default.removeItem(at: attachment.url) }

        #expect(found.count == 1)
        #expect(attachment.isImage)
        #expect(attachment.url.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
    }

    // Plain text is the text field's business, so nothing is attached and the paste is
    // left alone.
    @Test func ignoresPlainText() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("just some words", forType: .string)

        #expect(Attachments.fromClipboard(pasteboard).isEmpty)
    }

    // Copying cells from a spreadsheet puts a picture of them on the clipboard next to
    // the text. Attaching that picture would swallow a paste the user wanted as text.
    @Test func leavesTextAloneWhenAPictureOfItComesAlong() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("a\tb\n1\t2", forType: .string)
        pasteboard.setData(try pngData(), forType: .tiff)

        #expect(Attachments.fromClipboard(pasteboard).isEmpty)
    }

    @Test func ignoresDroppedWebAddresses() {
        let dropped = [URL(string: "https://example.com")!, URL(fileURLWithPath: "/tmp/a.png")]
        #expect(Attachments.fromDrop(dropped).map(\.name) == ["a.png"])
    }

    @Test func writesPastedTextToDisk() throws {
        let attachment = try #require(Attachments.fromPastedText("one\ntwo 💡"))
        defer { try? FileManager.default.removeItem(at: attachment.url) }

        #expect(attachment.name.hasPrefix("pasted-text-"))
        #expect(attachment.url.pathExtension == "txt")
        #expect(try String(contentsOf: attachment.url, encoding: .utf8) == "one\ntwo 💡")
    }

    @Test func onlyTreatsPastesAboveTheCharacterLimitAsTooLong() {
        let allowed = String(repeating: "💡", count: ComposerPaste.characterLimit)

        #expect(!ComposerPaste.isTooLong(allowed))
        #expect(ComposerPaste.isTooLong(allowed + "💡"))
    }

    // MARK: - What the CLI is told

    @Test func namesEveryAttachmentInThePrompt() {
        let attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/a.png")),
                           Attachment(url: URL(fileURLWithPath: "/tmp/b.txt"))]

        #expect(SessionRunner.prompt("look at this", with: attachments)
                == "look at this\n\nAttached files:\n- /tmp/a.png\n- /tmp/b.txt")
    }

    // An image on its own is a real ask, so it needs a sentence of its own.
    @Test func standsInForAPromptWhenOnlyFilesAreSent() {
        let attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/a.png"))]

        #expect(SessionRunner.prompt("", with: attachments) == "Look at these files:\n- /tmp/a.png")
        #expect(SessionRunner.prompt("plain", with: []) == "plain")
    }

    @Test func opensUpOnlyTheFoldersOutsideTheProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("src/main.swift")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("elsewhere-\(UUID().uuidString)/shot.png")

        let directories = SessionRunner.directoriesOutside(
            root.path,
            for: [Attachment(url: inside), Attachment(url: outside)])

        #expect(directories == [outside.deletingLastPathComponent().resolvingSymlinksInPath().path])
    }

    // Two screenshots share a folder, and naming it twice would only make the command longer.
    @Test func namesEachOutsideFolderOnce() {
        let folder = URL(fileURLWithPath: "/tmp/conductor-attachments")
        let attachments = [Attachment(url: folder.appendingPathComponent("one.png")),
                           Attachment(url: folder.appendingPathComponent("two.png"))]

        #expect(SessionRunner.directoriesOutside("/Users/someone/project", for: attachments)
                == [folder.resolvingSymlinksInPath().path])
    }

    @Test func attachmentsInsideAnyWorkspaceRootNeedNoExtraAccess() {
        let attachments = [Attachment(url: URL(fileURLWithPath: "/work/api/shot.png")),
                           Attachment(url: URL(fileURLWithPath: "/work/web/design/shot.png"))]

        #expect(SessionRunner.directoriesOutside(["/work/api", "/work/web"],
                                                 for: attachments).isEmpty)
    }

    @Test func rootMakesEveryAttachmentReachable() {
        let attachment = Attachment(url: URL(fileURLWithPath: "/tmp/shot.png"))

        #expect(SessionRunner.directoriesOutside("/", for: [attachment]).isEmpty)
    }
}
