import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The JSON box is typed into through the same calls a keystroke makes, so these follow
// what a person editing by hand would see.
@MainActor
struct JSONTextViewTests {
    private func editor(_ text: String = "", caret: Int? = nil) -> JSONTextView {
        let view = JSONTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return view
    }

    private func type(_ text: String, into view: JSONTextView) {
        view.insertText(text, replacementRange: view.selectedRange())
    }

    @Test func aCurlyQuoteTypedOutsideAStringLandsStraight() {
        let view = editor("{ ")
        type("\u{201C}", into: view)
        #expect(view.string == "{ \"")
    }

    @Test func aCurlyQuoteTypedInsideAStringIsKept() {
        let view = editor(#"{ "description": "the "#)
        type("\u{201C}", into: view)
        #expect(view.string == "{ \"description\": \"the \u{201C}")
    }

    @Test func germanQuotesTypedAroundAKeyBothLandStraight() {
        let view = editor("{ ")
        type("\u{201E}", into: view)
        type("command", into: view)
        type("\u{201C}", into: view)
        #expect(view.string == #"{ "command""#)
    }

    // The opener is forgotten when it is deleted, so a straight string that later starts
    // in the same place keeps the curly quotes typed in it.
    @Test func aDeletedCurlyOpenerIsForgotten() {
        let view = editor("{ ")
        type("\u{201E}", into: view)
        view.insertText("", replacementRange: NSRange(location: 2, length: 1))
        type("\"the ", into: view)
        type("\u{201C}", into: view)
        #expect(view.string == "{ \"the \u{201C}")
    }

    @Test func aCurlyOpenerMovesWithTextTypedBeforeIt() {
        let view = editor("{ ")
        type("\u{201E}", into: view)
        type("command", into: view)
        view.insertText("  ", replacementRange: NSRange(location: 1, length: 0))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        type("\u{201C}", into: view)
        #expect(view.string == #"{   "command""#)
    }

    @Test func anEnglishOpeningQuoteInAStraightValueStillStays() {
        let view = editor("{ ")
        type("\u{201E}", into: view)
        type("d\": \"the ", into: view)
        type("\u{201C}", into: view)
        #expect(view.string == "{ \"d\": \"the \u{201C}")
    }

    @Test func aTypedClosingCurlyQuoteEndsAKey() {
        let view = editor(#"{ "command"#)
        type("\u{201D}", into: view)
        #expect(view.string == #"{ "command""#)
    }

    @Test func returnKeepsTheIndentOfTheLineItLeaves() {
        let view = editor("{\n    \"a\": 1,")
        view.insertNewline(nil)
        #expect(view.string == "{\n    \"a\": 1,\n    ")
    }

    @Test func returnAfterAnOpenerStepsInALevel() {
        let view = editor("{\n  \"args\": [")
        view.insertNewline(nil)
        #expect(view.string == "{\n  \"args\": [\n    ")
    }

    @Test func returnBetweenAPairPutsTheCloserOnItsOwnLine() {
        let view = editor("{}", caret: 1)
        view.insertNewline(nil)
        #expect(view.string == "{\n  \n}")
        #expect(view.selectedRange().location == 4)
    }

    @Test func returnAfterTwoOpenersOnOneLineStepsInTwo() {
        let view = editor(#"{"a": {"#)
        view.insertNewline(nil)
        #expect(view.string == "{\"a\": {\n    ")
    }

    @Test func returnInsideAOneLineConfigStepsIntoIt() {
        let text = #"{"a": 1, "b": 2}"#
        let view = editor(text, caret: (text as NSString).range(of: ",").location + 1)
        view.insertNewline(nil)
        #expect(view.string == "{\"a\": 1,\n  \"b\": 2}")
    }

    @Test func returnBeforeTheCloserOfAFilledObjectLinesItUp() {
        let text = #"{"a": 1}"#
        let view = editor(text, caret: (text as NSString).length - 1)
        view.insertNewline(nil)
        #expect(view.string == "{\"a\": 1\n}")
        #expect(view.selectedRange().location == (view.string as NSString).length - 1)
    }

    @Test func bracketsInsideAStringDoNotIndent() {
        let view = editor(#"{"note": "a { b [","#)
        view.insertNewline(nil)
        #expect(view.string == "{\"note\": \"a { b [\",\n  ")
    }

    @Test func aTabIndentedLineStepsInByATab() {
        let view = editor("{\n\t\"a\": {")
        view.insertNewline(nil)
        #expect(view.string == "{\n\t\"a\": {\n\t\t")
    }

    @Test func aCloserOnATabIndentStepsBackATab() {
        let view = editor("{\n\t\"a\": {\n\t\t")
        type("}", into: view)
        #expect(view.string == "{\n\t\"a\": {\n\t}")
    }

    @Test func returnInsideTheIndentKeepsTheRestOfIt() {
        let text = "{\n  \"a\": 1\n}"
        let view = editor(text, caret: 2)
        view.insertNewline(nil)
        #expect(view.string == "{\n\n  \"a\": 1\n}")

        let deeper = editor("{\n    \"a\": 1\n}", caret: 3)
        deeper.insertNewline(nil)
        #expect(deeper.string == "{\n \n    \"a\": 1\n}")
    }

    @Test func aCloserTypedBeforeContentLeavesTheIndentAlone() {
        let text = "{\n    \"b\": 2"
        let view = editor(text, caret: (text as NSString).range(of: "\"b\"").location)
        type("}", into: view)
        #expect(view.string == "{\n    }\"b\": 2")
    }

    @Test func aCloserOnABlankIndentStepsBackOut() {
        let view = editor("{\n  \"a\": 1\n  ")
        type("}", into: view)
        #expect(view.string == "{\n  \"a\": 1\n}")
    }

    @Test func aCloserAfterTextIsTypedAsItIs() {
        let view = editor("[1  ")
        type("]", into: view)
        #expect(view.string == "[1  ]")
    }

    // A window gives the view the undo manager a real one would have, which gathers
    // everything done in one event into one step unless told otherwise.
    private func windowed(_ view: JSONTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        return window
    }

    private func clipboard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("json-editor-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    @Test func aPasteIntoAnEmptyBoxIsLaidOutAndUndoneInTwoSteps() throws {
        let pasted = #"{"fs":{"command":"npx"}}"#
        let view = editor()
        let window = windowed(view)
        view.pasteboard = clipboard(pasted)

        view.paste(nil)
        #expect(view.string == "{\n  \"fs\": {\n    \"command\": \"npx\"\n  }\n}")

        let undo = try #require(view.undoManager)
        undo.undo()
        #expect(view.string == pasted)
        undo.undo()
        #expect(view.string == "")
        _ = window
    }

    @Test func aPasteOverEverythingIsLaidOut() {
        let view = editor("old text")
        let window = windowed(view)
        view.pasteboard = clipboard(#"{"a":1}"#)
        view.selectAll(nil)
        view.paste(nil)
        #expect(view.string == "{\n  \"a\": 1\n}")
        _ = window
    }

    @Test func aValuePastedIntoTheMiddleLeavesTheLayoutAlone() {
        let text = "{\n    \"token\":   TOKEN\n}"
        let view = editor(text)
        let window = windowed(view)
        let token = (text as NSString).range(of: "TOKEN")
        view.setSelectedRange(token)
        view.pasteboard = clipboard(#""ghp_xyz""#)
        view.paste(nil)
        #expect(view.string == "{\n    \"token\":   \"ghp_xyz\"\n}")
        #expect(view.selectedRange().location == token.location + 9)
        _ = window
    }

    @Test func aPasteThatIsNotJSONIsLeftAsPasted() {
        let view = editor()
        let window = windowed(view)
        view.pasteboard = clipboard(#"{"a": "#)
        view.paste(nil)
        #expect(view.string == #"{"a": "#)
        _ = window
    }

    @Test func textReplacedFromOutsideForgetsTheOldUndoSteps() throws {
        let view = editor()
        let window = windowed(view)
        type(#"{"a": 1, "bbbbbbbbbbbbbbbbbb": 2}"#, into: view)
        view.replaceFromOutside(with: "{}")
        let undo = try #require(view.undoManager)
        #expect(!undo.canUndo)
        #expect(view.string == "{}")
        _ = window
    }

    // Format lays out what was typed by hand, as one step that Cmd+Z takes back.
    @Test func formattingTypedTextIsOneUndoStep() throws {
        let view = editor()
        let window = windowed(view)
        type(#"{"fs": {"command": "npx"}}"#, into: view)
        #expect(!view.status.formattable)   // waits for a pause in typing
        view.flushFormattableCheck()
        #expect(view.status.formattable)

        view.reformat()
        #expect(view.string == "{\n  \"fs\": {\n    \"command\": \"npx\"\n  }\n}")
        #expect(!view.status.formattable)
        #expect(view.status.formatted)

        try #require(view.undoManager).undo()
        #expect(view.string == #"{"fs": {"command": "npx"}}"#)
        _ = window
    }

    // Format keeps the caret with the characters it was beside.
    @Test func formattingKeepsTheCaretWhereItWas() {
        let text = #"{"a": 1, "bcd": 2}"#
        let view = editor(text, caret: (text as NSString).range(of: "cd").location)
        let window = windowed(view)
        view.reformat()
        #expect(view.string == "{\n  \"a\": 1,\n  \"bcd\": 2\n}")
        #expect(view.selectedRange().location == (view.string as NSString).range(of: "cd").location)
        _ = window
    }

    // After any run of edits the colours must be what painting the text afresh gives,
    // including after edits that change colours far from where they were made.
    @Test func paintingAfterEditsMatchesPaintingFromScratch() {
        let view = editor()
        let window = windowed(view)
        let pasted = #"{"mcpServers": {"a": {"url": "u", "n": 1, "on": true}}}"#
        view.pasteboard = clipboard(pasted)
        let s = { view.string as NSString }
        func expectFresh(_ note: Comment) {
            let fresh = editor()
            let freshWindow = windowed(fresh)
            fresh.replaceFromOutside(with: view.string)
            #expect(colours(of: view) == colours(of: fresh), note)
            _ = freshWindow
        }

        view.paste(nil)
        expectFresh("paste")
        view.selectAll(nil)
        view.paste(nil)
        expectFresh("the same paste again")

        view.insertText(#"{"b": {"command": "x"}},"#,
                        replacementRange: NSRange(location: s().range(of: "\"a\"").location, length: 0))
        expectFresh("a server typed on one line")
        view.reformat()
        expectFresh("Format")

        let comment = NSRange(location: s().range(of: "\"b\"").location, length: 0)
        view.insertText("/", replacementRange: comment)
        view.insertText("*", replacementRange: NSRange(location: comment.location + 1, length: 0))
        expectFresh("a block comment opened")
        view.insertText("", replacementRange: NSRange(location: comment.location + 1, length: 1))
        expectFresh("and its * deleted")
        view.insertText("", replacementRange: NSRange(location: comment.location, length: 1))

        view.insertText("mcpServerz", replacementRange: s().range(of: "mcpServers"))
        expectFresh("the wrapper renamed away")
        view.insertText("mcpServers", replacementRange: s().range(of: "mcpServerz"))
        expectFresh("and back")

        view.insertText("\u{201C}", replacementRange: NSRange(location: s().range(of: "\"u\"").location, length: 1))
        expectFresh("a straight quote made curly")
        _ = window
    }

    // A long text is painted once typing pauses, and then matches a fresh paint.
    @Test func aLongTextIsPaintedOnceTypingPauses() {
        let entries = (0..<1_500).map { "  \"setting\($0)\": \"value \($0)\"" }
        let long = "{\n" + entries.joined(separator: ",\n") + ",\n  \"mcp\": { \"servers\": { \"a\": { \"url\": \"u\" } } }\n}"
        #expect((long as NSString).length > JSONTextView.paintsAsYouTypeUpTo)
        let view = editor()
        let window = windowed(view)
        view.replaceFromOutside(with: long)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type("/* ", into: view)
        view.flushPendingPaint()

        let fresh = editor()
        let freshWindow = windowed(fresh)
        fresh.replaceFromOutside(with: view.string)
        #expect(colours(of: view) == colours(of: fresh))
        _ = (window, freshWindow)
    }

    private func colours(of view: NSTextView) -> [String] {
        let storage = view.textStorage!
        return (0..<storage.length).map {
            (storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor)?.description ?? "none"
        }
    }

    @Test func textStillBeingWrittenIsNotLaidOut() {
        let view = editor(#"{"fs": {"#)
        view.reformat()
        #expect(view.string == #"{"fs": {"#)
    }

    // A config pasted with four spaces carries on in four.
    @Test func returnAndTabStepByTheTextsOwnIndent() {
        let view = editor("{\n    \"a\": {")
        view.insertNewline(nil)
        #expect(view.string == "{\n    \"a\": {\n        ")

        let tabbed = editor("{\n    \"a\": 1,\n")
        tabbed.insertTab(nil)
        #expect(tabbed.string == "{\n    \"a\": 1,\n    ")
    }

    // However far off the line was, the closer lines up with the line that opened it.
    @Test func aCloserLinesUpWithItsOpener() {
        let over = editor("{\n  \"a\": [\n      ")
        type("]", into: over)
        #expect(over.string == "{\n  \"a\": [\n  ]")

        let under = editor("{\n    \"a\": [\n ")
        type("]", into: under)
        #expect(under.string == "{\n    \"a\": [\n    ]")
    }

    @Test func aCurlyQuoteAfterAnInchMarkOpensAString() {
        let view = editor("{\"size\": \"27\u{201D}, wide\", ")
        type("\u{201C}", into: view)
        #expect(view.string == "{\"size\": \"27\u{201D}, wide\", \"")
    }

    // Text set from outside and a Format asked for in the same update both happen, in
    // that order.
    @Test func formatAskedWithNewTextFormatsTheNewText() async throws {
        final class Box { var text = "{}" }
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let host = NSHostingView(rootView: JSONPayloadEditor(text: binding))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        box.text = #"{"a":1}"#
        host.rootView = JSONPayloadEditor(text: binding, formatRequest: 1)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func textView(in view: NSView) -> JSONTextView? {
            if let found = view as? JSONTextView { return found }
            return view.subviews.lazy.compactMap(textView(in:)).first
        }
        let view = try #require(textView(in: host))
        #expect(view.string == "{\n  \"a\": 1\n}")
        #expect(box.text == view.string)
    }

    // The Paste button selects everything to paste over it. With nothing the box can
    // read on the clipboard, the selection goes back, so the next keystroke does not wipe
    // the text.
    @Test func pasteOverEverythingWithNothingToReadKeepsTheSelection() {
        let view = editor(#"{"a": 1}"#, caret: 3)
        let window = windowed(view)
        let board = NSPasteboard(name: NSPasteboard.Name("json-editor-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        view.pasteboard = board
        #expect(!view.pasteOverEverything())
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
        #expect(view.string == #"{"a": 1}"#)
        _ = window
    }

    // Format lays the text out by its own step, the one Return and Tab use, and a config
    // already tidy in it has nothing to lay out.
    @Test func formatKeepsTheTextsOwnIndent() {
        let view = editor("{\n    \"a\": {\"b\": 1}\n}")
        let window = windowed(view)
        view.reformat()
        #expect(view.string == "{\n    \"a\": {\n        \"b\": 1\n    }\n}")

        let tidy = editor("{\n\t\"a\": 1\n}")
        tidy.recolour()
        tidy.flushFormattableCheck()
        #expect(!tidy.status.formattable)
        _ = window
    }

    // The text view fills the box, so a click below the last line still lands in it.
    // Hosted the way the sheet hosts it, and typed into, which is when a text view sizes
    // itself to its text.
    @Test func theTextFillsTheBoxEvenWhenShort() throws {
        final class Box { var text = "" }
        let box = Box()
        let host = NSHostingView(rootView: JSONPayloadEditor(text: Binding(get: { box.text }, set: { box.text = $0 }))
            .frame(width: 400, height: 260))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.center()
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> JSONTextView? {
            if let found = view as? JSONTextView { return found }
            return view.subviews.lazy.compactMap(textView(in:)).first
        }
        let view = try #require(textView(in: host))
        let scroll = try #require(view.enclosingScrollView)
        type("{}", into: view)
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        view.sizeToFit()
        host.layoutSubtreeIfNeeded()
        #expect(scroll.contentSize.height > 250)
        #expect(view.frame.height >= scroll.contentSize.height, "\(view.frame.height) vs \(scroll.contentSize.height)")
    }

    // Return after two openers puts the line two steps in, and that is not read as one
    // four-space step: the next level is still two spaces further.
    @Test func twoOpenersOnOneLineDoNotDoubleTheStep() {
        let view = editor(#"{"mcpServers": {"#)
        view.insertNewline(nil)
        type(#""x": {"#, into: view)
        view.insertNewline(nil)
        #expect(view.string == "{\"mcpServers\": {\n    \"x\": {\n      ")
    }

    // The first edit away from a layout clears the mark, and an undo that lands on the
    // laid-out text again does not bring it back.
    @Test func theFormattedMarkGoesWithTheFirstEdit() throws {
        let view = editor(#"{"a": 1}"#)
        let window = windowed(view)
        view.reformat()
        #expect(view.status.formatted)
        // A keystroke is an event of its own, and so its own undo step.
        let undo = try #require(view.undoManager)
        if undo.groupingLevel > 0 {
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
        }
        view.breakUndoCoalescing()
        type(" ", into: view)
        #expect(!view.status.formatted)
        undo.undo()
        #expect(view.string == "{\n  \"a\": 1\n}")
        #expect(!view.status.formatted)
        _ = window
    }

    // Past the size that is painted as it is typed, an edit puts Format away until the
    // paint has read the text again, so a click never lands on text that no longer reads.
    @Test func aLongTextPutsFormatAwayWhileTyping() {
        let body = (0..<400).map { "\"key\($0)\": \"value\($0)\"" }.joined(separator: ", ")
        let view = editor("{" + body + "}")
        let window = windowed(view)
        view.recolour()
        view.flushFormattableCheck()
        #expect(view.status.formattable)
        view.insertText("", replacementRange: NSRange(location: (view.string as NSString).length - 1, length: 1))
        #expect(!view.status.formattable)
        view.flushPendingPaint()
        #expect(!view.status.formattable)
        _ = window
    }

    // Undo is one action, like the Format it takes back, so a long text is read and
    // painted at once rather than after a pause.
    @Test func undoingAFormatOnALongTextIsReadAtOnce() async throws {
        let body = (0..<600).map { "\"key\($0)\": \"value\($0)\"" }.joined(separator: ", ")
        let view = editor("{" + body + "}")
        let window = windowed(view)
        #expect((view.string as NSString).length > JSONTextView.paintsAsYouTypeUpTo)
        view.recolour()
        view.reformat()
        try #require(view.undoManager).undo()
        #expect(view.string == "{" + body + "}")
        // AppKit tells of an undo only through the text storage; the box catches up on
        // it at the end of the turn of the run loop.
        try await Task.sleep(for: .milliseconds(20))
        // A read at once leaves a formattable check waiting; a deferred one does not.
        view.flushFormattableCheck()
        #expect(view.status.formattable)
        _ = window
    }

    // AppKit does not call didChangeText for an undo, so the box has to notice it some
    // other way, or the binding would keep the undone text and Add would import it.
    @Test func anUndoReachesTheBinding() async throws {
        final class Box { var text = "" }
        let box = Box()
        let host = NSHostingView(rootView: JSONPayloadEditor(text: Binding(get: { box.text }, set: { box.text = $0 }))
            .frame(width: 400, height: 260))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.center()
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> JSONTextView? {
            if let found = view as? JSONTextView { return found }
            return view.subviews.lazy.compactMap(textView(in:)).first
        }
        let view = try #require(textView(in: host))
        window.makeFirstResponder(view)
        type(#"{"a": 1}"#, into: view)
        #expect(box.text == #"{"a": 1}"#)
        try await Task.sleep(for: .milliseconds(20))
        try #require(view.undoManager).undo()
        try await Task.sleep(for: .milliseconds(20))
        #expect(view.string.isEmpty)
        #expect(box.text.isEmpty)
    }
}
