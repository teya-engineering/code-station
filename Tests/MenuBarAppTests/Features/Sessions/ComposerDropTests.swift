import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import MenuBarApp

@MainActor
struct ComposerDropTests {
    private final class ImagePromise: NSFilePromiseProvider {
        var fileURL: URL?

        override init() {
            super.init()
            fileType = UTType.png.identifier
        }

        override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            super.writableTypes(for: pasteboard) + (fileURL == nil ? [] : [.fileURL])
        }

        override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            if type == .fileURL { return fileURL?.absoluteString }
            return super.pasteboardPropertyList(forType: type)
        }
    }

    // Only what the text view reads off a drag is real; the rest is never asked for.
    @MainActor
    private final class Drag: NSObject, @preconcurrency NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { NSPoint(x: 20, y: 20) }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                    for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    private func editor(onDropFiles: (([URL]) -> Void)?,
                        onTargeted: @escaping (Bool) -> Void = { _ in }) -> (TextArea.EditorView, TextArea.Coordinator) {
        let area = TextArea(text: .constant(""), isFocused: .constant(false),
                            isEnabled: true, font: .systemFont(ofSize: 13),
                            onSubmit: {}, onOversizedPaste: { _ in },
                            onRecallUp: nil, onRecallDown: nil,
                            highlightsKeyword: false,
                            onSuggestionKey: nil, onCommandKey: nil,
                            onDropFiles: onDropFiles, onFileDragTargeted: onTargeted,
                            animatesKeyword: false, onHeightChange: { _ in })
        let coordinator = TextArea.Coordinator(area)
        let view = coordinator.makeField().documentView as! TextArea.EditorView
        return (view, coordinator)
    }

    private func pasteboard(with url: URL) -> NSPasteboard {
        pasteboard(with: [url as NSURL])
    }

    private func pasteboard(with items: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("composer-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard
    }

    @Test func fileDroppedOnTheTextBecomesAnAttachmentAndLeavesTheTextAlone() {
        var dropped: [URL] = []
        var targeted: [Bool] = []
        let (view, coordinator) = editor(onDropFiles: { dropped = $0 }, onTargeted: { targeted.append($0) })
        let file = URL(fileURLWithPath: "/tmp/screenshot.png")
        let drag = Drag(pasteboard(with: file))

        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.prepareForDragOperation(drag))
        #expect(view.performDragOperation(drag))
        view.concludeDragOperation(drag)

        #expect(dropped == [file])
        #expect(targeted == [true, false])
        #expect(view.string.isEmpty)
        _ = coordinator
    }

    @Test func fileDroppedAnywhereOnTheChatBecomesAnAttachment() {
        let view = FileDropView()
        var dropped: [URL] = []
        var targeted: [Bool] = []
        view.onDrop = { dropped += $0.map(\.url) }
        view.onTargeted = { targeted.append($0) }
        let file = URL(fileURLWithPath: "/tmp/screenshot.png")
        let drag = Drag(pasteboard(with: file))

        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.performDragOperation(drag))

        #expect(dropped == [file])
        #expect(targeted == [true, false])
    }

    @Test func mixedDropAttachesBothTheFileAndThePromise() throws {
        let file = URL(fileURLWithPath: "/tmp/existing.png")
        let promisedFile = URL(fileURLWithPath: "/tmp/promised.png")
        let promise = ImagePromise()
        let pasteboard = pasteboard(with: [file as NSURL, promise])
        defer { pasteboard.releaseGlobally() }
        let view = FileDropView()
        var dropped: [URL] = []
        var deliverPromise: (@MainActor () -> Void)?
        view.onDrop = { dropped += $0.map(\.url) }
        view.receivePromises = { promises, each, _ in
            #expect(promises.count == 1)
            #expect(promises.first?.fileTypes == [UTType.png.identifier])
            deliverPromise = { each(Attachment(url: promisedFile)) }
            return true
        }

        #expect(view.performDragOperation(Drag(pasteboard)))
        #expect(dropped == [file])
        let deliver = try #require(deliverPromise)
        deliver()

        #expect(dropped == [file, promisedFile])
    }

    @Test func promiseWinsWhenAnItemAlsoOffersAFileURL() throws {
        let promisedFile = URL(fileURLWithPath: "/tmp/full-image.png")
        let promise = ImagePromise()
        promise.fileURL = URL(fileURLWithPath: "/tmp/preview.png")
        let pasteboard = pasteboard(with: [promise])
        defer { pasteboard.releaseGlobally() }
        let view = FileDropView()
        var dropped: [URL] = []
        var deliverPromise: (@MainActor () -> Void)?
        view.onDrop = { dropped += $0.map(\.url) }
        view.receivePromises = { promises, each, _ in
            #expect(promises.count == 1)
            #expect(promises.first?.fileTypes == [UTType.png.identifier])
            deliverPromise = { each(Attachment(url: promisedFile)) }
            return true
        }

        #expect(view.performDragOperation(Drag(pasteboard)))
        #expect(dropped.isEmpty)
        let deliver = try #require(deliverPromise)
        deliver()

        #expect(dropped == [promisedFile])
    }

    @Test func mixedDropIsRefusedWhenPromisesCannotBeReceived() {
        let file = URL(fileURLWithPath: "/tmp/existing.png")
        let promise = ImagePromise()
        let pasteboard = pasteboard(with: [file as NSURL, promise])
        defer { pasteboard.releaseGlobally() }
        let view = FileDropView()
        var dropped: [URL] = []
        var receivedPromise = false
        view.onDrop = { dropped += $0.map(\.url) }
        view.receivePromises = { _, _, _ in
            receivedPromise = true
            return false
        }

        #expect(!view.performDragOperation(Drag(pasteboard)))
        #expect(receivedPromise)
        #expect(dropped.isEmpty)
    }

    @Test func chatDropLetsClicksAndTextThrough() {
        let view = FileDropView()

        #expect(view.hitTest(NSPoint(x: 1, y: 1)) == nil)
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        #expect(!view.registeredDraggedTypes.contains(.string))
    }

    @Test func chatThatCannotTakeFilesLetsTheDragThrough() {
        let view = FileDropView()
        var targeted: [Bool] = []
        view.onTargeted = { targeted.append($0) }
        view.isEnabled = false

        #expect(view.registeredDraggedTypes.isEmpty)
        #expect(view.draggingEntered(Drag(pasteboard(with: URL(fileURLWithPath: "/tmp/a.png")))) == [])
        #expect(targeted.isEmpty)

        view.isEnabled = true
        #expect(view.registeredDraggedTypes.contains(.fileURL))
    }

    @Test func webLinkIsNotTakenAsAFile() {
        let view = FileDropView()
        var targeted: [Bool] = []
        view.onTargeted = { targeted.append($0) }
        let drag = Drag(pasteboard(with: URL(string: "https://example.com/cat.png")!))

        #expect(view.draggingEntered(drag) == [])
        #expect(!view.performDragOperation(drag))
        #expect(targeted.isEmpty)
    }

    @Test func chatTurnedOffUnderADragPutsTheBoxOut() async {
        let view = FileDropView()
        var targeted: [Bool] = []
        view.onTargeted = { targeted.append($0) }

        #expect(view.draggingEntered(Drag(pasteboard(with: URL(fileURLWithPath: "/tmp/a.png")))) == .copy)
        view.isEnabled = false
        for _ in 0..<10 where targeted.count < 2 { await Task.yield() }

        #expect(targeted == [true, false])
    }

    @Test func fileDragIsLeftToTheTextViewWhenTheBoxTakesNoFiles() {
        var targeted: [Bool] = []
        let (view, coordinator) = editor(onDropFiles: nil, onTargeted: { targeted.append($0) })
        let drag = Drag(pasteboard(with: URL(fileURLWithPath: "/tmp/screenshot.png")))

        _ = view.draggingEntered(drag)

        #expect(targeted.isEmpty)
        _ = coordinator
    }
}
