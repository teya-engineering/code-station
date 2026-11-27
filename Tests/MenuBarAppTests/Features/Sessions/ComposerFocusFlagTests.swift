import AppKit
import Observation
import SwiftUI
import Testing
@testable import MenuBarApp

// A view can turn the composer's focus flag off while the cursor stays in the box, for
// example when a dialog opens over the chat. Pasting an image waits for that flag, so the
// box has to take an image pasted straight away, and turn the flag back on as soon as the
// person clicks, types or pastes in it again.
@MainActor
struct ComposerFocusFlagTests {

    @MainActor @Observable
    fileprivate final class Model {
        var text = ""
        var focused = false
        var pasted: [URL] = []
    }

    private struct Host: View {
        let model: Model

        var body: some View {
            @Bindable var model = model
            ComposerField(text: $model.text, isFocused: $model.focused, placeholder: "",
                          isEnabled: true, onSubmit: {}, onOversizedPaste: { _ in },
                          onPasteAttachments: { model.pasted += $0.map(\.url) }) { EmptyView() }
                .frame(width: 400, height: 200)
        }
    }

    @MainActor
    private final class Field {
        let model = Model()
        let window: NSWindow
        let editor: TextArea.EditorView

        init() throws {
            let hosting = NSHostingView(rootView: Host(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            Self.wait()
            editor = try #require(Self.editor(in: hosting))
            window.makeFirstResponder(editor)
            settle()
            // What a dialog opening over the chat does: the flag goes, the cursor stays.
            model.focused = false
            settle()
        }

        func close() {
            window.close()
            window.contentView = nil
        }

        func settle() { Self.wait() }

        static func wait() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        private static func editor(in view: NSView) -> TextArea.EditorView? {
            if let editor = view as? TextArea.EditorView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
    }

    @Test func typingInTheBoxTurnsTheFlagBackOn() throws {
        let field = try Field()
        defer { field.close() }
        #expect(field.window.firstResponder === field.editor)
        #expect(!field.model.focused)

        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: field.window.windowNumber,
                                                context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a",
                                                isARepeat: false, keyCode: 0))
        field.editor.keyDown(with: key)
        field.settle()

        #expect(field.model.focused)
        #expect(field.model.text == "a")
    }

    @Test func anImagePastedWhileTheFlagIsOffIsAttached() throws {
        let field = try Field()
        defer { field.close() }
        let pasteboard = NSPasteboard(name: .init("composer-focus-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        field.editor.pasteboard = pasteboard

        field.editor.paste(nil)
        field.settle()

        #expect(field.model.pasted.count == 1)
        #expect(field.model.pasted.first?.pathExtension == "png")
        #expect(field.model.focused)
        #expect(field.model.text.isEmpty)
        field.model.pasted.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
