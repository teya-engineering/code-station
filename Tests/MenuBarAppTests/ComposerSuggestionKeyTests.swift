import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// Tab, escape and command-return are borrowed by the suggestion above the composer, and
// the arrows, return, tab and escape by the command menu, in both cases only while there
// is one to answer. What matters is both halves of that: that the key reaches the row
// that is showing, and that the field hands it straight back when nothing is. These
// stand a real field up offscreen and press the keys at it.
@MainActor
struct ComposerSuggestionKeyTests {

    // What the field asked the suggestion about, kept apart from the field so the handler
    // can be written before the field it is given to exists.
    @MainActor
    private final class Notes {
        // False stands for a composer with nothing offered above it.
        var offers = true
        var lists = false
        var asked: [SuggestionKey] = []
        var askedCommands: [CommandKey] = []
        var recalled = 0
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    @MainActor
    private final class Field {
        let view: TextArea.EditorView
        let notes = Notes()
        private let submitted = Counter()
        private let window: NSWindow

        var sends: Int { submitted.count }

        var offers: Bool {
            get { notes.offers }
            set { notes.offers = newValue }
        }
        // Whether the command menu is open above the box.
        var lists: Bool {
            get { notes.lists }
            set { notes.lists = newValue }
        }
        var asked: [SuggestionKey] { notes.asked }
        var askedCommands: [CommandKey] { notes.askedCommands }
        var recalled: Int { notes.recalled }

        init() {
            let notes = self.notes
            let submitted = self.submitted
            let area = TextArea(text: .constant(""), isFocused: .constant(true),
                                isEnabled: true, font: .systemFont(ofSize: 13),
                                onSubmit: { submitted.count += 1 },
                                onOversizedPaste: { _ in },
                                onRecallUp: { notes.recalled += 1; return true },
                                onRecallDown: { notes.recalled += 1; return true },
                                highlightsKeyword: false,
                                onSuggestionKey: { key in
                                    guard notes.offers else { return false }
                                    notes.asked.append(key)
                                    return true
                                },
                                onCommandKey: { key in
                                    guard notes.lists else { return false }
                                    notes.askedCommands.append(key)
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

    // The menu is asked before anything else those keys mean, so return finishes the
    // name being typed instead of sending it, and the arrows walk the list rather than
    // the prompt history.
    @Test func handsTheMenuItsKeysBeforeAnythingElseTheyMean() {
        let field = Field()
        field.lists = true

        field.view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        field.view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        field.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        field.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        field.view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(field.askedCommands == [.up, .down, .complete, .complete, .cancel])
        #expect(field.sends == 0)
        #expect(field.recalled == 0)
        // Tab went to the menu rather than to the suggestion behind it.
        #expect(field.asked.isEmpty)
    }

    @Test func leavesTheKeysAloneWithNoMenuOpen() {
        let field = Field()

        field.view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        field.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(field.askedCommands.isEmpty)
        #expect(field.recalled == 1)
        #expect(field.sends == 1)
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
