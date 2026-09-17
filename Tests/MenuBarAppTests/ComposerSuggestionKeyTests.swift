import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// Tab, escape and command-return are borrowed by the suggestion above the composer only
// while there is one to answer. What matters is both halves of that: that the key reaches
// the suggestion when it is showing, and that the field hands it straight back when it is
// not. These stand a real field up offscreen and press the keys at it.
@MainActor
struct ComposerSuggestionKeyTests {

    // What the field asked the suggestion about, kept apart from the field so the handler
    // can be written before the field it is given to exists.
    @MainActor
    private final class Notes {
        // False stands for a composer with nothing offered above it.
        var offers = true
        var asked: [SuggestionKey] = []
    }

    @MainActor
    private final class Field {
        let view: TextArea.EditorView
        let notes = Notes()
        private let window: NSWindow

        var offers: Bool {
            get { notes.offers }
            set { notes.offers = newValue }
        }
        var asked: [SuggestionKey] { notes.asked }

        init() {
            let notes = self.notes
            let area = TextArea(text: .constant(""), isFocused: .constant(true),
                                isEnabled: true, font: .systemFont(ofSize: 13),
                                onSubmit: {}, onOversizedPaste: { _ in },
                                onRecallUp: nil, onRecallDown: nil,
                                highlightsKeyword: false,
                                onSuggestionKey: { key in
                                    guard notes.offers else { return false }
                                    notes.asked.append(key)
                                    return true
                                },
                                animatesKeyword: false,
                                onHeightChange: { _ in })
            let scrollView = TextArea.Coordinator(area).makeField()
            view = scrollView.documentView as! TextArea.EditorView
            scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView?.addSubview(scrollView)
            window.makeFirstResponder(view)
        }

        // Command-return never reaches the text-command path, so it is pressed as the key
        // equivalent it really is.
        func pressCommandReturn() -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36) else { return false }
            return view.performKeyEquivalent(with: event)
        }
    }

    @Test func handsTheThreeKeysToTheSuggestionWhileOneIsShowing() {
        let field = Field()

        field.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        field.view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(field.pressCommandReturn())

        #expect(field.asked == [.edit, .cancel, .send])
        // Tab was taken rather than typed into the prompt.
        #expect(field.view.string.isEmpty)
    }

    @Test func givesThemBackWhenThereIsNothingToAnswer() {
        let field = Field()
        field.offers = false

        field.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(!field.pressCommandReturn())

        #expect(field.asked.isEmpty)
    }

    // The key pressed hundreds of times a day keeps meaning "send the draft", so the
    // field never offers a plain return to the suggestion at all.
    @Test func neverOffersAPlainReturn() {
        let field = Field()

        field.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(field.asked.isEmpty)
    }
}
