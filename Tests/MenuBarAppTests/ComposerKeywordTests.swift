import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The field colours the thinking keyword with temporary attributes, which belong to the
// layout manager rather than to the text, so what a reader sees is only readable back off
// the layout manager. These stand a real field up offscreen and look there.
@MainActor
struct ComposerKeywordTests {

    @MainActor
    private final class Field {
        let view: TextArea.EditorView
        private let window: NSWindow

        init(_ text: String, highlights: Bool = true, animates: Bool = false) {
            let area = TextArea(text: .constant(text), isFocused: .constant(false),
                                isEnabled: true, font: .systemFont(ofSize: 13),
                                onSubmit: {}, onOversizedPaste: { _ in },
                                onRecallUp: nil, onRecallDown: nil,
                                highlightsKeyword: highlights,
                                onSuggestionKey: nil,
                                // A still word takes the colours of the first frame,
                                // which is all most of these need.
                                animatesKeyword: animates,
                                onHeightChange: { _ in })
            let scrollView = TextArea.Coordinator(area).makeField()
            view = scrollView.documentView as! TextArea.EditorView
            scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView?.addSubview(scrollView)
            view.highlightsKeyword = highlights
            view.animatesKeyword = animates
            view.refreshKeyword()
        }

        func colour(at index: Int) -> NSColor? {
            var effective = NSRange()
            return view.layoutManager?
                .temporaryAttributes(atCharacterIndex: index, effectiveRange: &effective)[.foregroundColor] as? NSColor
        }
    }

    @Test func coloursEveryLetterOfTheKeywordAndNothingElse() {
        let field = Field("please ultrathink now")

        #expect(field.colour(at: 0) == nil)
        for letter in 7..<17 {
            #expect(field.colour(at: letter) != nil)
        }
        #expect(field.colour(at: 17) == nil)
    }

    @Test func givesTheLettersDifferentColours() {
        let field = Field("ultrathink")

        #expect(field.colour(at: 0) != field.colour(at: 9))
    }

    @Test func leavesThePromptPlainForAgentsThatDoNotKnowTheWord() {
        let field = Field("ultrathink", highlights: false)

        #expect(field.colour(at: 0) == nil)
    }

    @Test func keepsTheColoursMovingOnlyWhileThereIsAWordToMoveThem() {
        #expect(Field("ultrathink", animates: true).view.isSweeping)
        #expect(!Field("nothing to see", animates: true).view.isSweeping)

        let field = Field("ultrathink", animates: true)
        field.view.insertText("ing", replacementRange: NSRange(location: 10, length: 0))

        #expect(!field.view.isSweeping)
    }

    @Test func dropsTheColoursOnceTypingMakesItAnotherWord() {
        let field = Field("ultrathink")

        field.view.insertText("ing", replacementRange: NSRange(location: 10, length: 0))

        #expect(field.view.string == "ultrathinking")
        #expect(field.colour(at: 0) == nil)
    }
}
