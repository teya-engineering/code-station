import AppKit
import Observation
import SwiftUI
import Testing
@testable import MenuBarApp

// A dead key, such as the backtick or an accent on many European keyboards, puts its mark
// in the field as marked text and waits for the next key. AppKit does not report marked
// text as a change, so the model lags the field until the mark is committed. These stand
// the real field up in SwiftUI, with the caret read back the way the composer reads it,
// so a caret move makes SwiftUI update the field while the mark is still waiting.
@MainActor
struct ComposerMarkedTextTests {

    // The draft lives outside the view, the way the composer's does.
    @MainActor @Observable
    fileprivate final class Model {
        var text = ""
    }

    private struct Host: View {
        let model: Model
        @State private var caret: ComposerCaret?

        var body: some View {
            @Bindable var model = model
            VStack {
                Text(caret.map { "\($0.text)|\($0.location ?? -1)" } ?? "")
                ComposerField(text: $model.text, isFocused: .constant(true), placeholder: "",
                              isEnabled: true, onSubmit: {}, onOversizedPaste: { _ in },
                              onCaretChange: { caret = $0 }) { EmptyView() }
            }
            .frame(width: 400, height: 200)
        }
    }

    @MainActor
    private final class Field {
        let model = Model()
        let view: TextArea.EditorView
        private let window: NSWindow

        init() {
            let hosting = NSHostingView(rootView: Host(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            Self.settle()
            view = Self.editor(in: hosting)!
            window.makeFirstResponder(view)
            Self.settle()
        }

        func close() {
            window.close()
            window.contentView = nil
        }

        // The keys a dead key sends: the mark first, then the committed text.
        func pressDeadKey(_ mark: String) {
            view.setMarkedText(mark, selectedRange: NSRange(location: (mark as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            Self.settle()
        }

        func commit(_ text: String) {
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            Self.settle()
        }

        static func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        private static func editor(in view: NSView) -> TextArea.EditorView? {
            if let editor = view as? TextArea.EditorView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
    }

    @Test func keepsADeadKeyMarkWhileItWaitsForTheNextKey() {
        let field = Field()
        defer { field.close() }

        field.pressDeadKey("`")

        #expect(field.view.hasMarkedText())
        #expect(field.view.string == "`")
        #expect(field.model.text == "")
    }

    @Test func committingTheMarkPutsItInTheDraft() {
        let field = Field()
        defer { field.close() }

        field.pressDeadKey("`")
        field.commit("`")

        #expect(!field.view.hasMarkedText())
        #expect(field.view.string == "`")
        #expect(field.model.text == "`")
    }

    @Test func aDraftChangedWhileAMarkWaitsStillReplacesTheField() {
        let field = Field()
        defer { field.close() }

        field.pressDeadKey("`")
        field.model.text = "recalled prompt"
        Field.settle()

        #expect(!field.view.hasMarkedText())
        #expect(field.view.string == "recalled prompt")
    }
}
