import AppKit
import SwiftUI

// The prompt box. SwiftUI's vertical-axis TextField settles on a wrapping width early and
// never revisits it, so lines break far short of the box they are drawn in and the top of
// the text scrolls out of view instead of the box growing. An NSTextView wraps to the
// width it is actually given, grows with the text, and is also the only way to tell
// return-to-send apart from shift-return-for-a-newline.
struct ComposerField<TrailingAccessory: View>: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onOversizedPaste: (String) -> Void
    let trailingAccessory: TrailingAccessory
    // Arrow-up on the first line asks for an earlier prompt, the way a shell recalls
    // history, and arrow-down on the last line comes back towards the present. Each
    // returns whether it had a prompt to give, so the key can fall through to ordinary
    // cursor movement when it did not.
    var onRecallUp: (() -> Bool)? = nil
    var onRecallDown: (() -> Bool)? = nil
    // Only Claude knows the thinking keyword, so only its prompts colour it.
    var highlightsKeyword: Bool = false
    var commandNames = SlashCommandNames()
    // Where the caret sits as it moves, so the command menu can follow the word it is in.
    var onCaretChange: ((ComposerCaret) -> Void)? = nil
    // Tab, command-return and escape while a suggestion is being offered above the box.
    // It answers whether it took the key, so with nothing offered tab still moves focus
    // and escape still reaches whatever else wants it.
    var onSuggestionKey: ((SuggestionKey) -> Bool)? = nil
    // The arrows, return, tab and escape while the command menu is open above the box.
    // It is asked before anything else those keys mean, and answers the same way.
    var onCommandKey: ((CommandKey) -> Bool)? = nil
    // Files dropped on the text itself, and whether such a drag is over it. Nil when the
    // box takes no files, so a drag over it does nothing.
    var onDropFiles: (([URL]) -> Void)? = nil
    var onFileDragTargeted: ((Bool) -> Void)? = nil
    // Images and files pasted into the box. Nil when the box takes no attachments.
    var onPasteAttachments: (([Attachment]) -> Void)? = nil
    // While the app is listening the words are the microphone's, so the box takes no
    // typing and wears the listening colour.
    var listening = false
    var marks = ComposerMarks()
    var onMarkClick: ((Int, CGRect) -> Void)? = nil
    var link: ComposerFieldLink? = nil
    // Room kept clear at the end of the text for whatever sits there.
    var trailingInset: CGFloat = 48

    // Past this the box stops growing and the text scrolls inside it, so a long prompt
    // can never push the transcript off the screen.
    private let maxLines = 10
    var minimumLines: Int = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 0

    init(text: Binding<String>, isFocused: Binding<Bool>, placeholder: String,
         isEnabled: Bool, onSubmit: @escaping () -> Void,
         onOversizedPaste: @escaping (String) -> Void,
         onRecallUp: (() -> Bool)? = nil,
         onRecallDown: (() -> Bool)? = nil,
         highlightsKeyword: Bool = false,
         commandNames: SlashCommandNames = SlashCommandNames(),
         onCaretChange: ((ComposerCaret) -> Void)? = nil,
         onSuggestionKey: ((SuggestionKey) -> Bool)? = nil,
         onCommandKey: ((CommandKey) -> Bool)? = nil,
         onDropFiles: (([URL]) -> Void)? = nil,
         onFileDragTargeted: ((Bool) -> Void)? = nil,
         onPasteAttachments: (([Attachment]) -> Void)? = nil,
         minimumLines: Int = 1,
         listening: Bool = false,
         marks: ComposerMarks = ComposerMarks(),
         onMarkClick: ((Int, CGRect) -> Void)? = nil,
         link: ComposerFieldLink? = nil,
         trailingInset: CGFloat = 48,
         @ViewBuilder trailingAccessory: () -> TrailingAccessory) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
        self.onOversizedPaste = onOversizedPaste
        self.onRecallUp = onRecallUp
        self.onRecallDown = onRecallDown
        self.highlightsKeyword = highlightsKeyword
        self.commandNames = commandNames
        self.onCaretChange = onCaretChange
        self.onSuggestionKey = onSuggestionKey
        self.onCommandKey = onCommandKey
        self.onDropFiles = onDropFiles
        self.onFileDragTargeted = onFileDragTargeted
        self.onPasteAttachments = onPasteAttachments
        self.trailingAccessory = trailingAccessory()
        self.minimumLines = minimumLines
        self.listening = listening
        self.marks = marks
        self.onMarkClick = onMarkClick
        self.link = link
        self.trailingInset = trailingInset
    }

    var body: some View {
        let font = NSFont.systemFont(ofSize: 13)
        let line = ceil(font.lineHeightForComposer)

        TextArea(text: $text,
                 isFocused: $isFocused,
                 isEnabled: isEnabled,
                 font: font,
                 onSubmit: onSubmit,
                 onOversizedPaste: onOversizedPaste,
                 onRecallUp: onRecallUp,
                 onRecallDown: onRecallDown,
                 highlightsKeyword: highlightsKeyword,
                 commandNames: commandNames,
                 onCaretChange: onCaretChange,
                 onSuggestionKey: onSuggestionKey,
                 onCommandKey: onCommandKey,
                 onDropFiles: onDropFiles,
                 onFileDragTargeted: onFileDragTargeted,
                 onPasteAttachments: onPasteAttachments,
                 readOnly: listening,
                 marks: marks,
                 onMarkClick: onMarkClick,
                 link: link,
                 animatesKeyword: !reduceMotion,
                 onHeightChange: { height = $0 })
            .frame(height: min(max(height, line * CGFloat(minimumLines)), line * CGFloat(maxLines)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, trailingInset)
            .padding(.vertical, Space.md)
            // The text view only covers the text itself, so the padding around it would
            // swallow a click and leave the box unfocused. The background sits behind the
            // text view and takes only the clicks it does not want, which is the padding.
            .background {
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(isFocused || listening ? Theme.card : Theme.field)
                    .onTapGesture { if isEnabled { isFocused = true } }
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(listening ? Theme.listenEdge : isFocused ? Theme.accent : Theme.border,
                        lineWidth: isFocused || listening ? 1.5 : 1))
            .background {
                if listening {
                    RoundedRectangle(cornerRadius: Radius.floating)
                        .stroke(Theme.listenGlow, lineWidth: 3)
                        .padding(-1.5)
                }
            }
            .motion(Motion.reveal, value: listening)
            .motion(Motion.hover, value: isFocused)
            .overlay(alignment: .trailing) {
                trailingAccessory
                    .padding(.trailing, Space.sm)
            }
    }
}

private extension NSFont {
    // The height one line of this font occupies once laid out, which is what the box has
    // to be a multiple of.
    var lineHeightForComposer: CGFloat { ascender - descender + leading }
}

struct TextArea: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let font: NSFont
    let onSubmit: () -> Void
    let onOversizedPaste: (String) -> Void
    let onRecallUp: (() -> Bool)?
    let onRecallDown: (() -> Bool)?
    let highlightsKeyword: Bool
    var commandNames = SlashCommandNames()
    var onCaretChange: ((ComposerCaret) -> Void)? = nil
    let onSuggestionKey: ((SuggestionKey) -> Bool)?
    let onCommandKey: ((CommandKey) -> Bool)?
    var onDropFiles: (([URL]) -> Void)? = nil
    var onFileDragTargeted: ((Bool) -> Void)? = nil
    var onPasteAttachments: (([Attachment]) -> Void)? = nil
    var readOnly = false
    var marks = ComposerMarks()
    var onMarkClick: ((Int, CGRect) -> Void)? = nil
    var link: ComposerFieldLink? = nil
    var submitsOnReturn = true
    var accessibilityLabel = "Prompt"
    let animatesKeyword: Bool
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeField()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }

        // Only when the model moved on its own, e.g. the draft cleared after a send.
        // Writing back what the user just typed would drop the insertion point.
        // Text still being composed, such as the accent a dead key holds until the next
        // key or a word an input method is building, is in the field but not yet in the
        // model, since AppKit reports the text only once it is committed. Writing the
        // model over it would throw the keystroke away, so it is kept unless the model
        // has changed since the field last matched it.
        let composing = textView.hasMarkedText() && text == context.coordinator.syncedText
        if textView.string != text, !composing {
            TextWash.clear(in: textView)
            textView.string = text
            // A prompt arriving from elsewhere is there to be worked on, so the caret
            // goes to the end of it rather than staying wherever the old text left it.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.reportHeight(of: textView)
        }
        context.coordinator.syncedText = text
        link?.textView = textView
        link?.applyPendingCaret()
        link?.applyPendingWash()

        // Still selectable while a turn runs: making it otherwise would push first
        // responder out of the box, and the cursor would not come back when the turn ends.
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isEditable = isEnabled && !readOnly
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor

        // Only ever claim focus, never clear it: handing it back to nobody would leave the
        // window with no first responder at all. Whatever the user moves to next takes it.
        // The claim is made once each time focus is asked for, not on every update. Two
        // fields bound to the same flag would otherwise take it from each other forever,
        // and every switch makes macOS build a new caret indicator, which piles up fast
        // enough to stall the whole machine.
        if isFocused, isEnabled {
            if !context.coordinator.claimedFocus, let window = textView.window {
                context.coordinator.claimedFocus = true
                if window.firstResponder !== textView {
                    DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
                }
            }
        } else {
            context.coordinator.claimedFocus = false
        }

        textView.highlightsKeyword = highlightsKeyword
        textView.commandNames = commandNames
        textView.animatesKeyword = animatesKeyword
        textView.marks = marks
        // After the colour above, which is written into the text and takes the keyword's
        // own colours off it.
        textView.refreshHighlights()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextArea
        private var lastHeight: CGFloat = -1
        private var lastCaret: ComposerCaret?
        var claimedFocus = false
        // Set while SwiftUI hands the field new state, when its own state cannot change.
        var updating = false
        // The text the field and the model last agreed on, which tells a change the model
        // made itself apart from text the field holds but has not reported yet.
        var syncedText: String

        init(_ parent: TextArea) {
            self.parent = parent
            syncedText = parent.text
        }

        // The box the field draws in. Separate from makeNSView so a test can stand one
        // up without a SwiftUI context.
        func makeField() -> NSScrollView {
            let textView = EditorView()
            textView.delegate = self
            textView.coordinator = self
            textView.font = parent.font
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            // The container follows the view's width, which is what makes the text wrap where
            // the box actually ends.
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.autoresizingMask = [.width]
            textView.string = parent.text
            textView.highlightsKeyword = parent.highlightsKeyword
            textView.animatesKeyword = parent.animatesKeyword
            textView.commandNames = parent.commandNames
            textView.marks = parent.marks
            textView.refreshHighlights()
            parent.link?.textView = textView

            let scrollView = NSScrollView()
            scrollView.documentView = textView
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScrollElasticity = .none
            return scrollView
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // A wash waiting for words a pick put in is stale once the person edits.
            parent.link?.dropPendingWash()
            parent.text = textView.string
            syncedText = textView.string
            reportHeight(of: textView)
            reportCaret(of: textView)
        }

        // The colour of a command being typed depends on where the caret is, so it is
        // worked out again whenever the caret moves.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? EditorView else { return }
            textView.refreshCommandColours()
            reportCaret(of: textView)
        }

        // A caret placed while SwiftUI is updating the field is passed on once the update
        // is over, and read again then, so only where it settled is reported.
        func reportCaret(of textView: NSTextView) {
            guard parent.onCaretChange != nil else { return }
            guard !updating else {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    reportCaret(of: textView)
                }
                return
            }
            let selection = textView.selectedRange()
            let caret = ComposerCaret(text: textView.string,
                                      location: selection.length == 0 ? selection.location : nil)
            guard caret != lastCaret else { return }
            lastCaret = caret
            parent.onCaretChange?(caret)
        }

        func handleOversizedPaste(from pasteboard: NSPasteboard) -> Bool {
            guard let text = pasteboard.string(forType: .string),
                  ComposerPaste.isTooLong(text) else { return false }
            parent.onOversizedPaste(text)
            return true
        }

        // Return sends and shift-return breaks the line. AppKit routes the shifted press
        // through the field-editor selector, but the plain one is checked for the modifier
        // too in case a key binding sends it here instead.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard parent.submitsOnReturn else { return false }
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else if !commandKey(.submit) {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Only ever borrowed: with no command to finish and no suggestion to
                // take, tab moves focus out of the box the way it does in every other
                // field.
                if commandKey(.complete) { return true }
                return suggestionKey(.edit)
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                // Escape arrives as cancelOperation:, which a text view turns into
                // complete: on the way, so both spellings are taken.
                if commandKey(.cancel) { return true }
                return suggestionKey(.cancel)
            case #selector(NSResponder.moveUp(_:)):
                // Only the first line recalls, so a press in the middle of a prompt that
                // runs over several lines is always the cursor's. Whether an earlier
                // prompt should replace what is there at all is the runner's call, since
                // only it knows a walk is under way.
                if commandKey(.up) { return true }
                if isOnFirstLine(textView), parent.onRecallUp?() == true { return true }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if commandKey(.down) { return true }
                if isOnLastLine(textView), parent.onRecallDown?() == true { return true }
                return false
            default:
                return false
            }
        }

        // Which line the caret is on, counted by the newlines the person typed rather
        // than by where the text happens to wrap, so the answer does not change with the
        // width of the window.
        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let caret = min(textView.selectedRange().location, text.length)
            return text.range(of: "\n", options: .backwards,
                              range: NSRange(location: 0, length: caret)).location == NSNotFound
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let caret = min(NSMaxRange(textView.selectedRange()), text.length)
            return text.range(of: "\n",
                              range: NSRange(location: caret, length: text.length - caret))
                .location == NSNotFound
        }

        func suggestionKey(_ key: SuggestionKey) -> Bool {
            parent.onSuggestionKey?(key) == true
        }

        func commandKey(_ key: CommandKey) -> Bool {
            parent.onCommandKey?(key) == true
        }

        func focusChanged(_ focused: Bool, in textView: NSTextView) {
            if parent.isFocused != focused { parent.isFocused = focused }
            // A field built with a draft already in it has not moved its caret yet.
            if focused { reportCaret(of: textView) }
        }

        // The box is sized from the laid-out text, so it has to be measured after every
        // change to the text and after every change to the width it wraps against.
        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            guard height != lastHeight else { return }
            lastHeight = height
            let report = parent.onHeightChange
            // Never during a layout pass: SwiftUI state cannot change while AppKit is
            // partway through laying the same view out.
            DispatchQueue.main.async { report(height) }
        }
    }

    final class EditorView: NSTextView {
        weak var coordinator: Coordinator?

        // Temporary attributes belong to the layout manager, so highlighting does not
        // change the prompt, enter the undo history, or colour the text typed after it.
        var highlightsKeyword = false
        var animatesKeyword = true
        var commandNames = SlashCommandNames()
        var marks = ComposerMarks()
        private var keywordRanges: [NSRange] = []
        private var commandRanges: [NSRange] = []
        private var sweep: Task<Void, Never>?
        private static let frameRate = Duration.milliseconds(42)

        // Whether the colours are moving, which is the one part of this that cannot be
        // read back off the attributes.
        var isSweeping: Bool { sweep != nil }

        func refreshHighlights() {
            keywordRanges = highlightsKeyword ? ThinkingKeyword.ranges(in: string) : []
            commandRanges = currentCommandRanges()

            if keywordRanges.isEmpty || !animatesKeyword {
                sweep?.cancel()
                sweep = nil
            } else if sweep == nil {
                sweep = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.frameRate)
                        guard let self else { return }
                        // A field SwiftUI has already taken out of its window has nothing
                        // to colour. The phase comes from the clock, so a skipped frame
                        // leaves the sweep where it should be rather than behind.
                        guard window != nil else { continue }
                        colourHighlights()
                    }
                }
            }
            colourHighlights()
        }

        // A caret move only changes the colour of the word it leaves or enters, and a
        // drag fires one of these for every step, so the rest is redrawn only when that
        // colour changes.
        func refreshCommandColours() {
            let ranges = currentCommandRanges()
            guard ranges != commandRanges else { return }
            commandRanges = ranges
            colourHighlights()
        }

        private func currentCommandRanges() -> [NSRange] {
            let selection = selectedRange()
            return SlashQuery.highlightedRanges(in: string,
                                                caret: selection.length == 0 ? selection.location : nil,
                                                names: commandNames)
        }

        private func colourHighlights() {
            guard let layoutManager else { return }

            let length = (string as NSString).length
            let whole = NSRange(location: 0, length: length)
            // AppKit shifts temporary ranges as text is edited, so their previous
            // offsets cannot tell us where all the old colour is now.
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
            }

            // A file name in backticks is sent as code, so it is shown as the same chip
            // here that it becomes in the transcript.
            for range in ComposerMarks.fileChips(in: string) {
                layoutManager.addTemporaryAttributes([.foregroundColor: Theme.accentNSColor,
                                                      .backgroundColor: Theme.accentNSColor.withAlphaComponent(0.08)],
                                                     forCharacterRange: range)
            }
            for range in marks.unsure where NSMaxRange(range) <= length {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    .underlineColor: Theme.listenEdgeNSColor
                ], forCharacterRange: range)
            }

            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let now = Date()
            for range in keywordRanges {
                for letter in 0..<range.length {
                    let colour = ThinkingKeyword.colour(letter: letter, of: range.length,
                                                        at: animatesKeyword ? now : ThinkingKeyword.still,
                                                        dark: dark)
                    layoutManager.setTemporaryAttributes([.foregroundColor: colour],
                                                         forCharacterRange: NSRange(location: range.location + letter,
                                                                                    length: 1))
                }
            }
            for range in commandRanges where NSMaxRange(range) <= length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.accentNSColor,
                                                    forCharacterRange: range)
            }
            // The words the engine is still guessing at, which may yet change.
            if let tentative = marks.tentative, NSMaxRange(tentative) <= length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                                    forCharacterRange: tentative)
            }
        }

        // A click on a dotted word asks about it rather than placing the caret.
        override func mouseDown(with event: NSEvent) {
            reclaimFocusFlag()
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if event.clickCount == 1, let handler = coordinator?.parent.onMarkClick,
               let mark = marks.unsure.firstIndex(where: {
                   NSLocationInRange(index, $0) || (index == NSMaxRange($0) && index > 0
                       && glyphRect(forCharacter: index - 1).contains(point))
               }),
               let frame = frameInWindow(of: marks.unsure[mark]) {
                handler(mark, frame)
                return
            }
            super.mouseDown(with: event)
        }

        private func glyphRect(forCharacter index: Int) -> NSRect {
            guard let layoutManager, let textContainer else { return .zero }
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                  actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }

        // Where a run of text sits in the window, measured from the top the way the
        // app's menus are placed.
        func frameInWindow(of range: NSRange) -> CGRect? {
            guard let layoutManager, let textContainer, let content = window?.contentView,
                  NSMaxRange(range) <= (string as NSString).length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let local = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            return FrameAnchor.fromTop(convert(local, to: content), in: content)
        }

        override func didChangeText() {
            super.didChangeText()
            // A wash marks where a command landed, and an edit moves the words under it.
            TextWash.clear(in: self)
            refreshHighlights()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                sweep?.cancel()
                sweep = nil
            } else {
                refreshHighlights()
            }
        }

        // Command-return is a key equivalent rather than a text command, so it never
        // reaches doCommandBySelector. It is only this field's while this field holds the
        // cursor, which is what keeps it from firing from anywhere else in the window.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "\r",
               coordinator?.suggestionKey(.send) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        // A text view is a drop target of its own and would take a file as its path in
        // the text, so only the padding around it ever reached the composer's drop. Files
        // are taken here instead and handed on as attachments; text drags stay AppKit's.
        private func droppedFiles(_ drag: NSDraggingInfo?) -> [URL] {
            guard let drag, coordinator?.parent.onDropFiles != nil else { return [] }
            return Pasteboard.fileURLs(from: drag.draggingPasteboard)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !droppedFiles(sender).isEmpty else { return super.draggingEntered(sender) }
            coordinator?.parent.onFileDragTargeted?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !droppedFiles(sender).isEmpty else { return super.draggingUpdated(sender) }
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            guard !droppedFiles(sender).isEmpty else { return super.draggingExited(sender) }
            coordinator?.parent.onFileDragTargeted?(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard !droppedFiles(sender).isEmpty else { return super.prepareForDragOperation(sender) }
            return true
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let files = droppedFiles(sender)
            guard !files.isEmpty else { return super.performDragOperation(sender) }
            coordinator?.parent.onFileDragTargeted?(false)
            coordinator?.parent.onDropFiles?(files)
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            guard droppedFiles(sender).isEmpty else { return }
            super.concludeDragOperation(sender)
        }

        // Tests swap in a private pasteboard, so they never touch the person's clipboard.
        var pasteboard = NSPasteboard.general

        // The composer's key monitor takes command-V first while its focus flag is on.
        // A paste that gets here came from the Edit menu, or arrived while the flag was
        // off with the cursor still in the box, so attachments are taken here too.
        override func paste(_ sender: Any?) {
            if let attach = coordinator?.parent.onPasteAttachments {
                let found = Attachments.fromClipboard(pasteboard)
                if !found.isEmpty {
                    reclaimFocusFlag()
                    attach(found)
                    return
                }
            }
            guard coordinator?.handleOversizedPaste(from: pasteboard) != true else { return }
            super.paste(sender)
        }

        // Re-wrapping happens here, so this is the one place that knows the text moved to
        // a different number of lines because the window changed size.
        override func layout() {
            super.layout()
            coordinator?.reportHeight(of: self)
        }

        override func becomeFirstResponder() -> Bool {
            let took = super.becomeFirstResponder()
            if took { coordinator?.focusChanged(true, in: self) }
            return took
        }

        // The view can turn the focus flag off without taking the cursor away, since
        // clearing focus would leave the window with no first responder. A click (see
        // mouseDown) or a key in the box then turns the flag back on. Otherwise everything
        // that waits for it, such as pasting an image, stays off while the person types here.
        override func keyDown(with event: NSEvent) {
            reclaimFocusFlag()
            super.keyDown(with: event)
        }

        private func reclaimFocusFlag() {
            guard window?.firstResponder === self, coordinator?.parent.isFocused == false else { return }
            coordinator?.focusChanged(true, in: self)
        }

        override func resignFirstResponder() -> Bool {
            let gave = super.resignFirstResponder()
            // A window merely losing key status is not the user moving focus elsewhere.
            if gave, window?.isKeyWindow == true { coordinator?.focusChanged(false, in: self) }
            return gave
        }
    }
}

// Where the caret sits, with the text it sits in. A draft can change from outside the field
// before the field has placed its caret in it, and the two are only read together.
struct ComposerCaret: Equatable {
    var text: String
    // Nil while there is a selection, when the caret is nowhere.
    var location: Int?
}

enum ComposerPaste {
    // This is about 5,000 tokens for typical English or code. Larger content is easier
    // to review as a file and can make AppKit lay out far more text than the prompt needs.
    static let characterLimit = 20_000

    static func isTooLong(_ text: String) -> Bool {
        text.count > characterLimit
    }
}

// What the field marks on the text without changing it.
struct ComposerMarks: Equatable {
    var tentative: NSRange?
    var unsure: [NSRange] = []

    // Only a lone file name in backticks, which is what a file said aloud becomes. Other
    // code in backticks stays plain, the way it was typed.
    private static let fileChip = try? NSRegularExpression(pattern: #"`[\w-]+(?:\.[\w-]+)*\.[A-Za-z0-9]+`"#)

    static func fileChips(in text: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return fileChip?.matches(in: text, range: whole).map(\.range) ?? []
    }
}

// Lets something outside the field read and move its caret, for words that have to go in
// where the person was typing rather than at the end.
@MainActor
final class ComposerFieldLink {
    weak var textView: NSTextView?
    private var pendingCaret: Int?
    private var pendingWash: (range: NSRange, words: String)?

    // The end of the selection, so a selection is kept and the words follow it.
    var caret: Int? {
        textView.map { NSMaxRange($0.selectedRange()) }
    }

    // The text is usually being changed in the same moment, so the caret is placed once
    // the field has the new text.
    func placeCaret(_ location: Int) {
        pendingCaret = location
        DispatchQueue.main.async { [weak self] in self?.applyPendingCaret() }
    }

    func applyPendingCaret() {
        guard let location = pendingCaret, let textView,
              location <= (textView.string as NSString).length else { return }
        pendingCaret = nil
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    // Words just put in are washed with the accent as they land, so a command that went
    // into the middle of a sentence shows where it went. Like the caret, the wash waits
    // until the field holds the words it is for.
    func wash(_ range: NSRange, holding words: String) {
        pendingWash = (range, words)
        DispatchQueue.main.async { [weak self] in self?.applyPendingWash() }
    }

    func dropPendingWash() {
        pendingWash = nil
    }

    func applyPendingWash() {
        guard let (range, words) = pendingWash, let textView else { return }
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == words else { return }
        pendingWash = nil
        TextWash.play(over: range, in: textView, colour: Theme.accentNSColor)
    }

    func frameInWindow(of range: NSRange) -> CGRect? {
        (textView as? TextArea.EditorView)?.frameInWindow(of: range)
    }

    func focus() {
        guard let textView, let window = textView.window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
    }
}
