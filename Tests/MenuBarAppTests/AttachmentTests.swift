import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MenuBarApp

// Reports what a view asks for when it is offered a width, which is how a picture that
// cannot be made narrower gives itself away.
private struct WidthProbe: Layout {
    let report: (CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        report(size.width)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

@MainActor
private final class MeasuredWidth {
    var value: CGFloat = 0
}

// Attachments are the one part of a prompt the user cannot see before it is sent: what
// reaches the CLI is a path, and a wrong one fails silently as a file the agent cannot
// read. These pin down what the clipboard turns into and what the CLI is told about it.
struct AttachmentTests {
    private let scratch = ScratchDirectory(prefix: "attachment-tests")
    private var root: URL { scratch.url }

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
        let folder = URL(fileURLWithPath: "/tmp/code-station-attachments")
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

    // The transcript shares its column with the working set, which docks beside it. An
    // image that held itself at the width it was drawn for would push that sidebar off
    // the edge of the window, so a narrow column has to make the picture narrow too.
    @MainActor
    @Test func aWideImageIsCappedByTheRoomItHasRatherThanHoldingItOpen() async throws {
        let file = root.appendingPathComponent("wide.png")
        try widePNG().write(to: file)

        let measured = MeasuredWidth()
        let host = NSHostingView(rootView: WidthProbe(report: { measured.value = $0 }) {
            InlineImageView(url: file, maximumWidth: 543)
                .environment(DialogPresenter())
                .environment(TooltipPresenter())
        })

        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        host.layoutSubtreeIfNeeded()
        // The picture is read off disk in the background, so its real size only arrives
        // a beat after the view does.
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        #expect(measured.value == 543)

        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value <= 300)
    }

    private func widePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 1884, height: 248))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1884, height: 248))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func rootMakesEveryAttachmentReachable() {
        let attachment = Attachment(url: URL(fileURLWithPath: "/tmp/shot.png"))

        #expect(SessionRunner.directoriesOutside("/", for: [attachment]).isEmpty)
    }
}
