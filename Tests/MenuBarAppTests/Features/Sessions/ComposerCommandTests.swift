import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ComposerCommandTests {
    @Test func returnInAProblemDescriptionInsertsANewlineWithoutSubmitting() {
        var sent = false
        let area = TextArea(text: .constant("Requests fail"), isFocused: .constant(false),
                            isEnabled: true, font: .systemFont(ofSize: 13),
                            onSubmit: { sent = true }, onOversizedPaste: { _ in },
                            onRecallUp: nil, onRecallDown: nil,
                            highlightsKeyword: false,
                            onSuggestionKey: nil, onCommandKey: nil,
                            submitsOnReturn: false,
                            animatesKeyword: false, onHeightChange: { _ in })
        let coordinator = TextArea.Coordinator(area)
        let view = coordinator.makeField().documentView as! TextArea.EditorView
        view.setSelectedRange(NSRange(location: 13, length: 0))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(view.string == "Requests fail\n")
        #expect(!sent)
    }

    @MainActor
    private final class Field {
        let view: TextArea.EditorView
        let coordinator: TextArea.Coordinator
        let window: NSWindow

        // `review` stands for a command that only runs first, and `backend:review` for a
        // skill the agent also picks up later in a prompt.
        init(_ text: String,
             commands: SlashCommandNames = SlashCommandNames(leading: ["review", "backend:review"],
                                                             inline: ["backend:review"]),
             highlightsKeyword: Bool = false, onCaretChange: ((ComposerCaret) -> Void)? = nil) {
            let area = TextArea(text: .constant(text), isFocused: .constant(false),
                                isEnabled: true, font: .systemFont(ofSize: 13),
                                onSubmit: {}, onOversizedPaste: { _ in },
                                onRecallUp: nil, onRecallDown: nil,
                                highlightsKeyword: highlightsKeyword,
                                commandNames: commands,
                                onCaretChange: onCaretChange,
                                onSuggestionKey: nil, onCommandKey: nil,
                                animatesKeyword: false, onHeightChange: { _ in })
            coordinator = TextArea.Coordinator(area)
            let scrollView = coordinator.makeField()
            view = scrollView.documentView as! TextArea.EditorView
            scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
            window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.makeFirstResponder(view)
        }

        func close() {
            window.close()
            window.contentView = nil
        }

        func colour(at index: Int) -> NSColor? {
            view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                   effectiveRange: nil) as? NSColor
        }
    }

    @Test func coloursTheCommandAsItIsTypedAndLeavesArgumentsPlain() {
        let field = Field("")
        defer { field.close() }

        for letter in "/review" {
            field.view.insertText(String(letter), replacementRange: field.view.selectedRange())
            for index in 0..<(field.view.string as NSString).length {
                #expect(field.colour(at: index) == Theme.accentNSColor)
            }
        }
        field.view.insertText(" this change", replacementRange: field.view.selectedRange())

        #expect(field.view.string == "/review this change")
        #expect(field.colour(at: 6) == Theme.accentNSColor)
        for index in 7..<(field.view.string as NSString).length {
            #expect(field.colour(at: index) == nil)
        }
    }

    @Test(arguments: ["/REVIEW changes", "  /review changes", "/backend:review\ncheck it"])
    func coloursCommandsInRestoredDrafts(prompt: String) {
        let field = Field(prompt)
        defer { field.close() }
        let slash = (prompt as NSString).range(of: "/").location

        #expect(field.colour(at: slash) == Theme.accentNSColor)
        #expect(field.view.string == prompt)
    }

    @Test(arguments: ["/unknown", "/tmp/file", "/review/file", "Try /review", "`/review`",
                      "```\n/review\n```", "/rev arguments", "/reviewer"])
    func leavesOtherTextPlain(prompt: String) {
        let field = Field(prompt)
        defer { field.close() }

        for index in 0..<(prompt as NSString).length {
            #expect(field.colour(at: index) == nil)
        }
    }

    @Test func removesColourWhenEditsMoveOrInvalidateTheCommand() {
        let field = Field("/review")
        defer { field.close() }
        field.view.insertText("Please ", replacementRange: NSRange(location: 0, length: 0))

        for index in 0..<(field.view.string as NSString).length {
            #expect(field.colour(at: index) == nil)
        }

        field.view.insertText("/review", replacementRange: NSRange(location: 0, length: 14))
        #expect(field.colour(at: 0) == Theme.accentNSColor)
        field.view.insertText("", replacementRange: NSRange(location: 0, length: 1))

        #expect(field.view.string == "review")
        for index in 0..<6 {
            #expect(field.colour(at: index) == nil)
        }
    }

    @Test func refreshingCommandNamesKeepsTheSelectionAndText() {
        let field = Field("/review changes", commands: SlashCommandNames())
        defer { field.close() }
        let selection = NSRange(location: 2, length: 4)
        field.view.setSelectedRange(selection)
        #expect(field.colour(at: 0) == nil)

        field.view.commandNames = SlashCommandNames(leading: ["review"])
        field.view.refreshHighlights()

        #expect(field.colour(at: 0) == Theme.accentNSColor)
        #expect(field.view.selectedRange() == selection)
        #expect(field.view.string == "/review changes")

        field.view.commandNames = SlashCommandNames()
        field.view.refreshHighlights()
        #expect(field.colour(at: 0) == nil)
    }

    @Test func keepsHighlightingOutOfTheTextAndUndoHistory() throws {
        let field = Field("/review")
        defer { field.close() }
        let undo = try #require(field.view.undoManager)
        undo.removeAllActions()
        let stored = try #require(field.view.textStorage).copy() as! NSAttributedString
        let typingAttributes = NSDictionary(dictionary: field.view.typingAttributes)

        field.view.refreshHighlights()

        #expect(field.view.textStorage?.isEqual(to: stored) == true)
        #expect(NSDictionary(dictionary: field.view.typingAttributes) == typingAttributes)
        #expect(!undo.canUndo)

        field.view.insertText("x", replacementRange: NSRange(location: 7, length: 0))
        #expect(field.colour(at: 0) == nil)
        field.view.breakUndoCoalescing()
        undo.undo()

        #expect(field.view.string == "/review")
        #expect(field.colour(at: 0) == Theme.accentNSColor)
    }

    @Test func sharesTheFieldWithThinkingKeywordColours() {
        let field = Field("/review ultrathink", highlightsKeyword: true)
        defer { field.close() }

        #expect(field.colour(at: 0) == Theme.accentNSColor)
        #expect(field.colour(at: 7) == nil)
        #expect(field.colour(at: 8) != nil)
        #expect(field.colour(at: 8) != field.colour(at: 17))
    }

    @Test func theInputBoxUpdatesItsColoursWhenCommandsLoad() throws {
        func field(commands: SlashCommandNames) -> ComposerField<EmptyView> {
            ComposerField(text: .constant("/review changes"), isFocused: .constant(false),
                          placeholder: "Ask for a change", isEnabled: true,
                          onSubmit: {}, onOversizedPaste: { _ in }, commandNames: commands) {
                EmptyView()
            }
        }
        let host = NSHostingView(rootView: field(commands: SlashCommandNames()))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        host.layoutSubtreeIfNeeded()

        var descendants = host.subviews
        var editor: TextArea.EditorView?
        while let view = descendants.popLast() {
            if let found = view as? TextArea.EditorView { editor = found; break }
            descendants.append(contentsOf: view.subviews)
        }
        let view = try #require(editor)
        let selection = NSRange(location: 8, length: 7)
        view.setSelectedRange(selection)

        host.rootView = field(commands: SlashCommandNames(leading: ["review"]))
        host.layoutSubtreeIfNeeded()

        #expect(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                       effectiveRange: nil) as? NSColor == Theme.accentNSColor)
        #expect(view.selectedRange() == selection)
        #expect(view.string == "/review changes")
    }

    @Test func coloursEveryCommandThatRunsWhereItSits() {
        let prompt = "/review then /backend:review. Not /review or /backend:reviewz"
        let field = Field(prompt)
        defer { field.close() }
        field.view.setSelectedRange(NSRange(location: 0, length: 0))
        let text = prompt as NSString

        let later = text.range(of: "/backend:review").location
        #expect(field.colour(at: 0) == Theme.accentNSColor)
        #expect(field.colour(at: 6) == Theme.accentNSColor)
        #expect(field.colour(at: later) == Theme.accentNSColor)
        #expect(field.colour(at: later + 14) == Theme.accentNSColor)
        // The full stop after the name is the sentence's, not the command's.
        #expect(field.colour(at: later + 15) == nil)
        // A command that only runs first, and a name nothing is called, stay plain later on.
        #expect(field.colour(at: text.range(of: "/review or").location) == nil)
        #expect(field.colour(at: text.range(of: "/backend:reviewz").location) == nil)
    }

    @Test func aLaterWordBeingTypedIsColouredOnlyWhileTheCaretIsAtItsEnd() {
        let field = Field("")
        defer { field.close() }
        field.view.insertText("then /back", replacementRange: field.view.selectedRange())

        #expect(field.colour(at: 5) == Theme.accentNSColor)
        #expect(field.colour(at: 9) == Theme.accentNSColor)
        #expect(field.colour(at: 0) == nil)

        // Away from the caret, a part of a name is not a command.
        field.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(field.colour(at: 5) == nil)
        field.view.setSelectedRange(NSRange(location: 10, length: 0))
        #expect(field.colour(at: 5) == Theme.accentNSColor)
    }

    @Test func reportsTheCaretAsItMovesAndNothingForASelection() {
        var carets: [ComposerCaret] = []
        let field = Field("", onCaretChange: { carets.append($0) })
        defer { field.close() }

        field.view.insertText("/rev", replacementRange: field.view.selectedRange())
        #expect(carets.last == ComposerCaret(text: "/rev", location: 4))
        field.view.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(carets.last == ComposerCaret(text: "/rev", location: nil))
        field.view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(carets.last == ComposerCaret(text: "/rev", location: 2))
        // An edit that leaves the caret where it was still says which text it is in.
        field.view.insertText("", replacementRange: NSRange(location: 2, length: 1))
        #expect(carets.last == ComposerCaret(text: "/rv", location: 2))
    }

    @Test func aCommandPutInIsWashedUntilTheTextIsEdited() {
        let field = Field("then /address-pr-comments ")
        defer { field.close() }
        let link = ComposerFieldLink()
        link.textView = field.view
        let before = field.view.subviews.count

        // The wash waits until the field holds the words it is for.
        link.wash(NSRange(location: 5, length: 20), holding: "/address-pr-comment")
        link.applyPendingWash()
        #expect(field.view.subviews.count == before)

        link.wash(NSRange(location: 5, length: 20), holding: "/address-pr-comments")
        link.applyPendingWash()
        #expect(field.view.subviews.count == before + 1)

        field.view.insertText("x", replacementRange: NSRange(location: 26, length: 0))
        #expect(field.view.subviews.count == before)
    }

    @Test func returnAndTabAskTheMenuDifferently() {
        var keys: [CommandKey] = []
        var sent = false
        let area = TextArea(text: .constant("then /add"), isFocused: .constant(false),
                            isEnabled: true, font: .systemFont(ofSize: 13),
                            onSubmit: { sent = true }, onOversizedPaste: { _ in },
                            onRecallUp: nil, onRecallDown: nil,
                            highlightsKeyword: false,
                            onSuggestionKey: nil,
                            onCommandKey: { keys.append($0); return false },
                            animatesKeyword: false, onHeightChange: { _ in })
        let coordinator = TextArea.Coordinator(area)
        let view = coordinator.makeField().documentView as! TextArea.EditorView
        view.setSelectedRange(NSRange(location: 9, length: 0))

        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(keys == [.complete, .submit])
        // The menu turned return down, so it sends.
        #expect(sent)
    }

    @Test func aWashThatNeverLandedIsDroppedOnceThePersonEdits() {
        let link = ComposerFieldLink()
        let area = TextArea(text: .constant("then "), isFocused: .constant(false),
                            isEnabled: true, font: .systemFont(ofSize: 13),
                            onSubmit: {}, onOversizedPaste: { _ in },
                            onRecallUp: nil, onRecallDown: nil,
                            highlightsKeyword: false,
                            onSuggestionKey: nil, onCommandKey: nil,
                            link: link,
                            animatesKeyword: false, onHeightChange: { _ in })
        let coordinator = TextArea.Coordinator(area)
        let view = coordinator.makeField().documentView as! TextArea.EditorView
        link.textView = view
        let before = view.subviews.count

        // The pick was overtaken, so its words never arrive.
        link.wash(NSRange(location: 5, length: 5), holding: "/tidy")
        link.applyPendingWash()
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("/tidy", replacementRange: view.selectedRange())
        link.applyPendingWash()

        #expect(view.subviews.count == before)
    }
}
