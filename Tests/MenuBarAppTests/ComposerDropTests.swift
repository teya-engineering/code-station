import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ComposerDropTests {
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
        let pasteboard = NSPasteboard(name: .init("composer-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
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

    @Test func fileDragIsLeftToTheTextViewWhenTheBoxTakesNoFiles() {
        var targeted: [Bool] = []
        let (view, coordinator) = editor(onDropFiles: nil, onTargeted: { targeted.append($0) })
        let drag = Drag(pasteboard(with: URL(fileURLWithPath: "/tmp/screenshot.png")))

        _ = view.draggingEntered(drag)

        #expect(targeted.isEmpty)
        _ = coordinator
    }
}
