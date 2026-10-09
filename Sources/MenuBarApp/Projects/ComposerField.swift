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
    var commandNames: Set<String> = []
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
         commandNames: Set<String> = [],
         onSuggestionKey: ((SuggestionKey) -> Bool)? = nil,
         onCommandKey: ((CommandKey) -> Bool)? = nil,
         onDropFiles: (([URL]) -> Void)? = nil,
         onFileDragTargeted: ((Bool) -> Void)? = nil,
         minimumLines: Int = 1,
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
        self.onSuggestionKey = onSuggestionKey
        self.onCommandKey = onCommandKey
        self.onDropFiles = onDropFiles
        self.onFileDragTargeted = onFileDragTargeted
        self.trailingAccessory = trailingAccessory()
        self.minimumLines = minimumLines
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
                 onSuggestionKey: onSuggestionKey,
                 onCommandKey: onCommandKey,
                 onDropFiles: onDropFiles,
                 onFileDragTargeted: onFileDragTargeted,
                 animatesKeyword: !reduceMotion,
                 onHeightChange: { height = $0 })
            .frame(height: min(max(height, line * CGFloat(minimumLines)), line * CGFloat(maxLines)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 48)
            .padding(.vertical, 10)
            // The text view only covers the text itself, so the padding around it would
            // swallow a click and leave the box unfocused. The background sits behind the
            // text view and takes only the clicks it does not want, which is the padding.
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? Theme.card : Theme.field)
                    .onTapGesture { if isEnabled { isFocused = true } }
            }
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.accent : Theme.border, lineWidth: isFocused ? 1.5 : 1))
            .overlay(alignment: .trailing) {
                trailingAccessory
                    .padding(.trailing, 6)
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
    var commandNames: Set<String> = []
    let onSuggestionKey: ((SuggestionKey) -> Bool)?
    let onCommandKey: ((CommandKey) -> Bool)?
    var onDropFiles: (([URL]) -> Void)? = nil
    var onFileDragTargeted: ((Bool) -> Void)? = nil
    let animatesKeyword: Bool
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeField()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorView else { return }
        context.coordinator.parent = self

        // Only when the model moved on its own, e.g. the draft cleared after a send.
        // Writing back what the user just typed would drop the insertion point.
        if textView.string != text {
            textView.string = text
            // A prompt arriving from elsewhere is there to be worked on, so the caret
            // goes to the end of it rather than staying wherever the old text left it.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.reportHeight(of: textView)
        }

        // Still selectable while a turn runs: making it otherwise would push first
        // responder out of the box, and the cursor would not come back when the turn ends.
        textView.setAccessibilityLabel("Prompt")
        textView.isEditable = isEnabled
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
        // After the colour above, which is written into the text and takes the keyword's
        // own colours off it.
        textView.refreshHighlights()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextArea
        private var lastHeight: CGFloat = -1
        var claimedFocus = false

        init(_ parent: TextArea) { self.parent = parent }

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
            textView.refreshHighlights()

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
            parent.text = textView.string
            reportHeight(of: textView)
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
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else if !commandKey(.complete) {
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

        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
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
        var commandNames: Set<String> = []
        private var keywordRanges: [NSRange] = []
        private var commandRange: NSRange?
        private var sweep: Task<Void, Never>?
        private static let frameRate = Duration.milliseconds(42)

        // Whether the colours are moving, which is the one part of this that cannot be
        // read back off the attributes.
        var isSweeping: Bool { sweep != nil }

        func refreshHighlights() {
            keywordRanges = highlightsKeyword ? ThinkingKeyword.ranges(in: string) : []
            commandRange = SlashQuery.highlightedRange(in: string, commandNames: commandNames)

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

        private func colourHighlights() {
            guard let layoutManager else { return }

            let length = (string as NSString).length
            // AppKit shifts temporary ranges as text is edited, so their previous
            // offsets cannot tell us where all the old colour is now.
            layoutManager.removeTemporaryAttribute(.foregroundColor,
                                                   forCharacterRange: NSRange(location: 0, length: length))

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
            if let commandRange {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.accentNSColor,
                                                    forCharacterRange: commandRange)
            }
        }

        override func didChangeText() {
            super.didChangeText()
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

        override func paste(_ sender: Any?) {
            guard coordinator?.handleOversizedPaste(from: .general) != true else { return }
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
            if took { coordinator?.focusChanged(true) }
            return took
        }

        override func resignFirstResponder() -> Bool {
            let gave = super.resignFirstResponder()
            // A window merely losing key status is not the user moving focus elsewhere.
            if gave, window?.isKeyWindow == true { coordinator?.focusChanged(false) }
            return gave
        }
    }
}

enum ComposerPaste {
    // This is about 5,000 tokens for typical English or code. Larger content is easier
    // to review as a file and can make AppKit lay out far more text than the prompt needs.
    static let characterLimit = 20_000

    static func isTooLong(_ text: String) -> Bool {
        text.count > characterLimit
    }
}
