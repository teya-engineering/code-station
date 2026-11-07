import AppKit
import SwiftUI

// The box a server's JSON is pasted or typed into. It behaves like a small code editor
// rather than a prose field: quotes stay straight, Return keeps the indent and opens a
// level after { or [, a closing bracket steps back out, and a paste that makes up the
// whole text is laid out at once if it reads as JSON. What someone is in the middle of
// editing is never rewritten under them; typed text is laid out only when asked, through
// `formatRequest`.
//
// Laying out is its own step in the text view's undo, so Cmd+Z brings back the text
// exactly as it was pasted, and a second Cmd+Z takes the paste away.
struct JSONPayloadEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    // Bumped by a Paste button outside the box. The box pastes over its whole text the way
    // Cmd+V would, so the button lays out and undoes exactly as the shortcut does.
    var pasteRequest = 0
    // Bumped by a Format button outside the box. Typed text is never laid out on its own,
    // so this is how it is asked for; it is one step in the box's undo.
    var formatRequest = 0
    // Called when what the box shows about its text changes. See `Status`.
    var onStatus: (Status) -> Void = { _ in }
    // Called when a paste request finds no text on the clipboard.
    var onNothingToPaste: () -> Void = {}

    // What the box knows about its text, for the view around it to show.
    struct Status: Equatable {
        // Which servers the text holds, as last read. Not where they are written: that
        // moves with every character typed before it, and nothing around the box shows it.
        var servers: JSONPayload.Servers?
        // Whether the text reads as JSON and a format request would lay it out differently.
        var formattable = false
        // Whether the text is exactly as the box last laid it out. The first edit away
        // clears it, so an undo or redo that lands on the same text again does not bring
        // it back.
        var formatted = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.handledPasteRequest = pasteRequest
        coordinator.handledFormatRequest = formatRequest
        coordinator.writtenText = text

        let textView = JSONTextView(frame: .zero)
        textView.delegate = coordinator
        textView.onStatus = { [weak coordinator] in coordinator?.statusChanged($0) }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: textView.font as Any, .foregroundColor: NSColor.labelColor]
        textView.insertionPointColor = Theme.accentNSColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.turnOffProseHelpers()
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Server JSON")
        textView.string = text
        textView.recolour()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? JSONTextView else { return }

        // Text replaced from outside goes in first, so a paste or a format asked for in the
        // same update acts on it. Only when it was replaced: writing back what was just
        // typed would drop the insertion point.
        //
        // Compared first with the very string the box last wrote to the binding, which
        // while typing is the binding's own and so compares at once. Two equal texts
        // bridged apart compare character by character, about 4 ms at 65,000 units, on
        // every update.
        if text != coordinator.writtenText {
            coordinator.writtenText = text
            if textView.string != text { textView.replaceFromOutside(with: text) }
        }
        if pasteRequest != coordinator.handledPasteRequest {
            coordinator.handledPasteRequest = pasteRequest
            // Not during this update: the paste writes the text back to SwiftUI, which
            // drops state changed while it is updating, and the next update would then
            // put the old text back over the paste.
            let nothingToPaste = onNothingToPaste
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                if !textView.pasteOverEverything() { nothingToPaste() }
            }
        }
        if formatRequest != coordinator.handledFormatRequest {
            coordinator.handledFormatRequest = formatRequest
            // Deferred for the same reason as the paste, and so after it when both came.
            DispatchQueue.main.async { [weak textView] in textView?.reformat() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONPayloadEditor
        var handledPasteRequest = 0
        var handledFormatRequest = 0
        // The text as the box last wrote it to the binding, or was last given it.
        var writtenText = ""
        private var reportedStatus: Status?
        private var pendingStatus: Status?
        private var reportScheduled = false
        // The box's own undo history, apart from the window's, so text replaced from
        // outside can drop it whole without touching any other field's.
        private let undoManager = UndoManager()

        init(_ parent: JSONPayloadEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.string
            writtenText = text
            parent.text = text
        }

        // Everything the box reports during one turn of the run loop reaches SwiftUI in
        // one go, as its last state: Format both hides the link and sets the mark, and
        // shown one at a time they would flash a row with neither. Never during an update
        // either, since a paste can land while SwiftUI is updating the view.
        func statusChanged(_ status: Status) {
            pendingStatus = status
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reportScheduled = false
                guard let status = pendingStatus else { return }
                pendingStatus = nil
                guard status != reportedStatus else { return }
                reportedStatus = status
                parent.onStatus(status)
            }
        }
    }
}

final class JSONTextView: NSTextView {
    static let indentUnit = "  "
    // What the import leaves behind, such as an "mcpServers" wrapper, is drawn in this.
    static let leftOutColor = NSColor.tertiaryLabelColor
    var onStatus: ((JSONPayloadEditor.Status) -> Void)?
    private(set) var status = JSONPayloadEditor.Status()
    // Where Paste reads from. Tests hand it a private pasteboard so they leave the
    // clipboard alone.
    var pasteboard = NSPasteboard.general

    // Past this many UTF-16 units, painting and reading the whole text on every keystroke
    // would hold typing up (about 7 ms a keystroke here, 20 ms at 23,000), so typing
    // waits for a pause before the box is painted and read again. A server's snippet is
    // far shorter; this is for a whole settings file pasted in. A paste, Format, an undo
    // or redo, or new text from outside is one action rather than a run of keystrokes, so
    // it is painted at once at any size (see `didChangeText`).
    static let paintsAsYouTypeUpTo = 8_000
    // Set while a paste or Format changes the text, which `didChangeText` then paints at
    // once rather than as typing.
    private var changingAsOneAction = false

    // Laying the text out to compare it is a full pass, so it waits for a pause in typing.
    private var formattableCheck: DispatchWorkItem?
    // A paint of a long text, waiting for typing to pause.
    private var pendingPaint: DispatchWorkItem?
    // Where a typed curly quote opened a string. See `insertText`.
    private var curlyOpenerAt: Int?
    // The edit AppKit announced before the change now being made, and how many it
    // announced. The opener above is moved by it.
    private var announcedEdit: (range: NSRange, length: Int)?
    private var announcedEdits = 0
    // The text as last painted and read, so Format and a typed quote do not read it
    // again. Not the parsed value: a whole settings file's tree would be held between
    // keystrokes for nothing.
    private var lastReading: (edit: Int, text: String, parses: Bool)?
    // Bumped by every change to the text, so a reading can tell it is out of date
    // without holding a copy of the text to compare.
    private var edits = 0

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            edits += 1
            // Set from outside, which paints on its own; not an edit to catch up on.
            storageChangedUnannounced = false
        }
    }

    // MARK: - Changes AppKit does not announce

    // Undo and redo change the text without calling `didChangeText`, so nothing would
    // tell the binding, the paint or the status that the text is different: the box would
    // show the undone text and Add would import the one before it. The text storage
    // reports every change to its characters, so one that no `didChangeText` follows by
    // the end of this turn of the run loop is handled as a change of its own.
    private var storageChangedUnannounced = false
    private var watchingStorage = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        watchStorage()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        watchStorage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        watchStorage()
    }

    private func watchStorage() {
        guard !watchingStorage else { return }
        watchingStorage = true
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: nil)
    }

    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage, storage === textStorage,
              storage.editedMask.contains(.editedCharacters), !storageChangedUnannounced else { return }
        storageChangedUnannounced = true
        DispatchQueue.main.async { [weak self] in
            guard let self, storageChangedUnannounced else { return }
            // An undo or redo is one action, not typing, so it is painted at once.
            changingAsOneAction = true
            didChangeText()
            changingAsOneAction = false
        }
    }

    // At least as tall as the box, so a click anywhere in it below the last line lands
    // in the text and puts the caret at the end, as it did in a TextEditor.
    override func setFrameSize(_ newSize: NSSize) {
        let visible = enclosingScrollView?.contentSize.height ?? 0
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, visible)))
    }

    // Text that arrives from outside rather than by an edit. What the undo stack
    // remembers was done to the old text, and replaying it on the new one would land in
    // the wrong places, so all of it goes. The editor keeps an undo manager of its own,
    // so this clears nothing anywhere else in the window.
    func replaceFromOutside(with text: String) {
        string = text
        undoManager?.removeAllActions()
        curlyOpenerAt = nil
        update { $0.formatted = false }
        recolour()
    }

    private func update(_ change: (inout JSONPayloadEditor.Status) -> Void) {
        var next = status
        change(&next)
        guard next != status else { return }
        status = next
        onStatus?(next)
    }

    // MARK: - Following edits

    // AppKit announces every edit it makes for the user here, typed, pasted, deleted or
    // undone, with the exact characters replaced. (NSTextStorage also reports edits, but
    // as the span of everything it touched in a pass, which is often far wider.)
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        if let replacementString {
            announcedEdit = (affectedCharRange, (replacementString as NSString).length)
            announcedEdits += 1
        }
        return true
    }

    // Moves the opener past the edit just made. One that came unannounced, or with
    // others, cannot be followed, so the opener is forgotten; that only means a German
    // closing quote typed in that string stays as typed.
    private func followEdit() {
        defer {
            announcedEdit = nil
            announcedEdits = 0
        }
        guard let opener = curlyOpenerAt else { return }
        guard announcedEdits == 1, let edit = announcedEdit else {
            curlyOpenerAt = nil
            return
        }
        let moved = Self.moved(opener, by: edit.range, edit.length - edit.range.length)
        let text = string as NSString
        curlyOpenerAt = moved.flatMap { $0 < text.length && text.character(at: $0) == JSONScanner.quote ? $0 : nil }
    }

    // Where the character at `offset` is after `replaced` became `delta` units longer, or
    // nil when it was itself replaced.
    private static func moved(_ offset: Int, by replaced: NSRange, _ delta: Int) -> Int? {
        if offset < replaced.location { return offset }
        if offset >= NSMaxRange(replaced) { return offset + delta }
        return nil
    }

    // MARK: - Colour

    override func didChangeText() {
        super.didChangeText()
        storageChangedUnannounced = false
        edits += 1
        followEdit()
        update { $0.formatted = false }
        let oneAction = changingAsOneAction || undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if oneAction || (textStorage?.length ?? 0) <= Self.paintsAsYouTypeUpTo {
            recolour()
        } else {
            // Until the paint reads the text again, nobody knows whether it still parses,
            // so Format is put away rather than offered for text it may not lay out.
            formattableCheck?.cancel()
            formattableCheck = nil
            update { $0.formattable = false }
            pendingPaint?.cancel()
            let paint = DispatchWorkItem { [weak self] in self?.recolour() }
            pendingPaint = paint
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: paint)
        }
    }

    // Paints the whole text: syntax colour from the shared highlighter, then the part
    // outside the servers greyed over it. Colour is an attribute of the storage, not an
    // edit, so undo never sees it. Always the whole text, because what colour a line
    // takes can depend on any other: a block comment, a quote straightened elsewhere, the
    // grey's edges, the size limit. Past the highlighter's size limit only the syntax
    // colour is skipped: the grey is what the note under the box points at, so it is
    // always drawn.
    func recolour() {
        pendingPaint?.cancel()
        pendingPaint = nil
        guard let storage = textStorage else { return }
        let source = storage.string
        let reading = JSONPayload.read(source)
        let length = storage.length
        // Straightening swaps one UTF-16 unit for another, so offsets into the reading
        // are offsets into the box (JSONPayloadTests checks every quote it swaps). Should
        // a quote ever be added that breaks that, the box is painted from its own text
        // with no grey, rather than in the wrong places.
        let aligned = (reading.text as NSString).length == length
        assert(aligned, "straightening changed the text's length")
        lastReading = (edits, reading.text, reading.parses)
        let scope = aligned ? JSONPayload.serverScope(in: reading) : nil
        let text = (aligned ? reading.text : source) as NSString

        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor,
                             range: NSRange(location: 0, length: length))
        // Measured the way every other highlighter caller measures it, in UTF-8 bytes.
        if source.utf8.count <= CodeHighlight.sizeLimit {
            var state = CodeHighlight.State.normal
            var lineStart = 0
            while lineStart < length {
                var contentsEnd = 0
                var lineEnd = 0
                text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                                  for: NSRange(location: lineStart, length: 0))
                let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                storage.paintCode(line[...], at: lineStart, language: .json, state: &state)
                lineStart = lineEnd
            }
        }
        if let scope, !scope.wrapper.isEmpty {
            let tail = NSMaxRange(scope.range)
            storage.addAttribute(.foregroundColor, value: Self.leftOutColor,
                                 range: NSRange(location: 0, length: scope.range.location))
            storage.addAttribute(.foregroundColor, value: Self.leftOutColor,
                                 range: NSRange(location: tail, length: length - tail))
        }
        storage.endEditing()

        update { $0.servers = scope?.servers }
        checkFormattable(after: reading, of: source)
    }

    #if DEBUG
    // Runs a paint still waiting for typing to pause, for tests that have no pause to wait out.
    func flushPendingPaint() {
        pendingPaint?.perform()
    }
    #endif

    // Whether Format would change anything, told once typing pauses. Text that does not
    // read has nothing to lay out, and saying so costs nothing, so that is told at once.
    private func checkFormattable(after reading: JSONPayload.Reading, of source: String) {
        formattableCheck?.cancel()
        formattableCheck = nil
        guard reading.parses else {
            update { $0.formattable = false }
            return
        }
        let text = reading.text
        // The step is read when the check runs, not now: the next keystroke cancels it.
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            formattableCheck = nil
            let formattable = JSONFormat.layout(text, indent: indentStep(), droppingTrailingCommas: true) != source
            update { $0.formattable = formattable }
        }
        formattableCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    #if DEBUG
    // Runs a check still waiting for the pause, for tests that have no pause to wait out.
    func flushFormattableCheck() {
        let check = formattableCheck
        check?.perform()
        check?.cancel()
    }
    #endif

    // MARK: - Typing

    // A keyboard layout or an Option key can still type a curly quote with the
    // substitution off. Where it opens or closes a string it lands as `"`; where it is
    // a quotation mark inside a value it stays (see JSONPayload.typedQuoteIsStructural).
    // A string a curly quote opened is remembered, so its partner closes it whichever
    // kind it is, as “ does after „ in German.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard var typed = (string as? String) ?? (string as? NSAttributedString)?.string else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        var straightened = false
        var opensAt: Int?
        if typed.unicodeScalars.count == 1, let quote = typed.unicodeScalars.first,
           JSONPayload.curlyDoubleQuotes.contains(quote) {
            // Read as the JSON reader reads it when the text parses that way; as written
            // otherwise, since straightening text that does not parse is only a guess.
            let reading = currentReading()
            let state = JSONPayload.stringState(of: reading.parses ? reading.text : self.string,
                                                at: target.location)
            let openedCurly = state.inString && state.start == curlyOpenerAt
            if JSONPayload.typedQuoteIsStructural(quote, in: state, openedCurly: openedCurly) {
                typed = "\""
                straightened = true
                opensAt = state.inString ? nil : target.location
            }
        }
        if typed == "}" || typed == "]", let dedent = dedent(closing: replacementRange) {
            super.insertText(dedent.indent + typed, replacementRange: dedent.range)
        } else {
            super.insertText(typed, replacementRange: replacementRange)
        }
        // Recorded after the insert, which would otherwise move it along as an edit
        // in front of it.
        if straightened { curlyOpenerAt = opensAt }
    }

    // The step the text is indented by, read from its first indented line: a tab when
    // that line starts with one, otherwise its spaces shared out over the brackets it sits
    // inside. So a config pasted with tabs or four spaces is carried on in them, and a
    // line Return put two steps in after `{"mcpServers": {` still reads as two-space.
    // Two spaces while nothing is indented yet, or when the line does not divide evenly.
    private func indentStep() -> String {
        let text = string as NSString
        var lineStart = 0
        while lineStart < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: lineStart, length: 0))
            var index = lineStart
            while index < contentsEnd, JSONScanner.isIndent(text.character(at: index)) { index += 1 }
            // A line of nothing but spaces says nothing about the indent.
            if index > lineStart, index < contentsEnd {
                if text.character(at: lineStart) == 0x09 { return "\t" }
                let before = Array(text.substring(to: lineStart).utf16)
                var depth = JSONScanner.openBrackets(in: before).count
                // A closer sits one step out from what it closes.
                let first = text.character(at: index)
                if first == JSONScanner.closeBrace || first == JSONScanner.closeBracket { depth -= 1 }
                let width = index - lineStart
                guard depth > 0, width.isMultiple(of: depth), width / depth <= 8 else { return Self.indentUnit }
                return String(repeating: " ", count: width / depth)
            }
            lineStart = lineEnd
        }
        return Self.indentUnit
    }

    // The spaces and tabs a line starts with, up to `location` at most.
    private func indentOfLine(at location: Int) -> (lineStart: Int, indent: String) {
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        var end = lineStart
        while end < location, JSONScanner.isIndent(text.character(at: end)) { end += 1 }
        return (lineStart, text.substring(with: NSRange(location: lineStart, length: end - lineStart)))
    }

    // A closing bracket typed on a line that holds only its indent takes the indent of
    // the line that opened the bracket it closes, so it lines up however far off the
    // line was. Typed in front of anything else on the line, it goes in where it was
    // typed. Returns the indent to replace and what replaces it.
    private func dedent(closing replacementRange: NSRange) -> (range: NSRange, indent: String)? {
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard selection.length == 0 else { return nil }
        let (lineStart, indent) = indentOfLine(at: selection.location)
        guard (indent as NSString).length == selection.location - lineStart,
              restOfLineIsBlank(after: selection.location) else { return nil }
        let before = Array((string as NSString).substring(to: lineStart).utf16)
        guard let opener = JSONScanner.openBrackets(in: before).last else { return nil }
        let aligned = indentOfLine(at: opener.at).indent
        guard aligned != indent else { return nil }
        return (NSRange(location: lineStart, length: selection.location - lineStart), aligned)
    }

    private func restOfLineIsBlank(after location: Int) -> Bool {
        let text = string as NSString
        var index = location
        while index < text.length, JSONScanner.isIndent(text.character(at: index)) { index += 1 }
        // Past the spaces and tabs, the line has ended or something is on it.
        return index == text.length || JSONScanner.isWhitespace(text.character(at: index))
    }

    // The new line starts at the indent of the one it leaves, one step further in for
    // each bracket that line opened and has not closed yet. So Return after
    // `{"a": {` lands two steps in, and Return inside a config typed on one line
    // steps into it rather than back to the margin.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        let (lineStart, indent) = indentOfLine(at: selection.location)
        let lineHead = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let open = JSONScanner.openBrackets(in: lineHead)
        // Spaces the caret sat in front of would push the new line off its indent. Inside
        // the indent itself they are the rest of the indent of the line being pushed down,
        // and they stay with it.
        var after = NSMaxRange(selection)
        let caretInIndent = indent.utf16.count == lineHead.utf16.count
        while !caretInIndent, after < text.length, JSONScanner.isIndent(text.character(at: after)) {
            after += 1
        }
        let replaced = NSRange(location: selection.location, length: after - selection.location)
        let closer: UInt16? = after < text.length ? text.character(at: after) : nil

        guard let innermost = open.last else {
            return super.insertText("\n" + indent, replacementRange: replaced)
        }
        let step = indentStep()
        let inner = indent + String(repeating: step, count: open.count)
        let outer = indent + String(repeating: step, count: open.count - 1)
        guard closer == JSONScanner.closer(of: innermost) else {
            return super.insertText("\n" + inner, replacementRange: replaced)
        }
        // Return between an empty pair, as in {|}, puts the closing bracket on a line of
        // its own and leaves the caret on the indented line between them. Anywhere else
        // before it, as in {"a": 1|}, the bracket just moves down to line up.
        if lineHead.last(where: { !$0.isWhitespace })?.utf16.first == innermost {
            super.insertText("\n" + inner + "\n" + outer, replacementRange: replaced)
            setSelectedRange(NSRange(location: selection.location + ("\n" + inner as NSString).length,
                                     length: 0))
        } else {
            super.insertText("\n" + outer, replacementRange: replaced)
        }
    }

    override func insertTab(_ sender: Any?) {
        super.insertText(indentStep(), replacementRange: selectedRange())
    }

    // MARK: - Pasting

    // Only a paste that makes up the whole text is laid out: one into an empty box, or
    // over everything. A value pasted into the middle of a config is left where it went,
    // with the layout around it and the caret after it.
    override func paste(_ sender: Any?) {
        pasteFromBoard()
    }

    // Pastes over the whole text, the way Cmd+A then Cmd+V would, for the Paste button.
    // When the clipboard holds nothing the box can read, such as an image, the selection
    // goes back to what it was: left selected, the whole text would go with the next
    // keystroke. Returns whether anything was pasted.
    func pasteOverEverything() -> Bool {
        let selection = selectedRange()
        selectAll(nil)
        guard pasteFromBoard() else {
            setSelectedRange(selection)
            return false
        }
        return true
    }

    @discardableResult
    private func pasteFromBoard() -> Bool {
        let text = string as NSString
        let outside = text.replacingCharacters(in: selectedRange(), with: "")
        let isWholeText = outside.allSatisfy(\.isWhitespace)
        changingAsOneAction = true
        defer { changingAsOneAction = false }
        guard readSelection(from: pasteboard) else { return false }
        if isWholeText { reformat() }
        return true
    }

    // The box is plain text already, so matching the style is the same paste.
    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    // Lays the whole text out again, as a step of its own that Cmd+Z can take back. Text
    // that does not read as JSON is left alone. The caret stays with the characters it
    // was beside and is scrolled into view.
    func reformat() {
        let source = string
        let reading = currentReading()
        guard reading.parses else { return }
        // By the text's own step, the one Return and Tab use, so a config pasted with
        // tabs or four spaces is laid out in them, and one already tidy in them is left.
        let laidOut = JSONFormat.layout(reading.text, indent: indentStep(), droppingTrailingCommas: true,
                                        caret: selectedRange().location)
        guard laidOut.text != source else { return }
        let whole = NSRange(location: 0, length: (source as NSString).length)
        // The undo manager gathers everything done in one event into one step, which
        // would fold this into the paste before it. Closing that step here keeps them
        // apart; the event still closes the one opened in its place.
        if let undoManager, undoManager.groupsByEvent, undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: whole, replacementString: laidOut.text) else { return }
        textStorage?.replaceCharacters(in: whole,
                                       with: NSAttributedString(string: laidOut.text, attributes: typingAttributes))
        let wasOneAction = changingAsOneAction
        changingAsOneAction = true
        didChangeText()
        changingAsOneAction = wasOneAction
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: laidOut.caret, length: 0))
        scrollRangeToVisible(selectedRange())
        // What was just laid out has nothing left to lay out.
        formattableCheck?.cancel()
        formattableCheck = nil
        update {
            $0.formattable = false
            $0.formatted = true
        }
    }

    // The text as the JSON reader takes it: from the last paint when that read the text
    // as it stands, read again when a paint is still waiting for typing to pause.
    private func currentReading() -> (text: String, parses: Bool) {
        if let last = lastReading, last.edit == edits { return (last.text, last.parses) }
        let fresh = JSONPayload.read(string)
        return (fresh.text, fresh.parses)
    }
}
