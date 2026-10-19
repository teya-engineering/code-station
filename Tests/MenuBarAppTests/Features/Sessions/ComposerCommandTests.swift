import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
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

        init(_ text: String, commands: Set<String> = ["review", "backend:review"],
             highlightsKeyword: Bool = false) {
            let area = TextArea(text: .constant(text), isFocused: .constant(false),
                                isEnabled: true, font: .systemFont(ofSize: 13),
                                onSubmit: {}, onOversizedPaste: { _ in },
                                onRecallUp: nil, onRecallDown: nil,
                                highlightsKeyword: highlightsKeyword,
                                commandNames: commands,
                                onSuggestionKey: nil, onCommandKey: nil,
                                animatesKeyword: false, onHeightChange: { _ in })
            coordinator = TextArea.Coordinator(area)
            let scrollView = coordinator.makeField()
            view = scrollView.documentView as! TextArea.EditorView
            scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
            window = testWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
            window.contentView = scrollView
            window.makeFirstResponder(view)
        }

        func colour(at index: Int) -> NSColor? {
            view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                   effectiveRange: nil) as? NSColor
        }
    }

    @Test func coloursTheCommandAsItIsTypedAndLeavesArgumentsPlain() {
        let field = Field("")

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
        let slash = (prompt as NSString).range(of: "/").location

        #expect(field.colour(at: slash) == Theme.accentNSColor)
        #expect(field.view.string == prompt)
    }

    @Test(arguments: ["/unknown", "/tmp/file", "/review/file", "Try /review", "`/review`",
                      "```\n/review\n```", "/rev arguments", "/reviewer"])
    func leavesOtherTextPlain(prompt: String) {
        let field = Field(prompt)

        for index in 0..<(prompt as NSString).length {
            #expect(field.colour(at: index) == nil)
        }
    }

    @Test func removesColourWhenEditsMoveOrInvalidateTheCommand() {
        let field = Field("/review")
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
        let field = Field("/review changes", commands: [])
        let selection = NSRange(location: 2, length: 4)
        field.view.setSelectedRange(selection)
        #expect(field.colour(at: 0) == nil)

        field.view.commandNames = ["review"]
        field.view.refreshHighlights()

        #expect(field.colour(at: 0) == Theme.accentNSColor)
        #expect(field.view.selectedRange() == selection)
        #expect(field.view.string == "/review changes")

        field.view.commandNames = []
        field.view.refreshHighlights()
        #expect(field.colour(at: 0) == nil)
    }

    @Test func keepsHighlightingOutOfTheTextAndUndoHistory() throws {
        let field = Field("/review")
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

        #expect(field.colour(at: 0) == Theme.accentNSColor)
        #expect(field.colour(at: 7) == nil)
        #expect(field.colour(at: 8) != nil)
        #expect(field.colour(at: 8) != field.colour(at: 17))
    }

    @Test func theInputBoxUpdatesItsColoursWhenCommandsLoad() throws {
        func field(commands: Set<String>) -> ComposerField<EmptyView> {
            ComposerField(text: .constant("/review changes"), isFocused: .constant(false),
                          placeholder: "Ask for a change", isEnabled: true,
                          onSubmit: {}, onOversizedPaste: { _ in }, commandNames: commands) {
                EmptyView()
            }
        }
        let host = NSHostingView(rootView: field(commands: []))
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

        host.rootView = field(commands: ["review"])
        host.layoutSubtreeIfNeeded()

        #expect(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                       effectiveRange: nil) as? NSColor == Theme.accentNSColor)
        #expect(view.selectedRange() == selection)
        #expect(view.string == "/review changes")
    }
}
