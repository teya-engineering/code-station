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
    // Tab, command-return and escape while a suggestion is being offered above the box.
    // It answers whether it took the key, so with nothing offered tab still moves focus
    // and escape still reaches whatever else wants it.
    var onSuggestionKey: ((SuggestionKey) -> Bool)? = nil

    // Past this the box stops growing and the text scrolls inside it, so a long prompt
    // can never push the transcript off the screen.
    private let maxLines = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 0

    init(text: Binding<String>, isFocused: Binding<Bool>, placeholder: String,
         isEnabled: Bool, onSubmit: @escaping () -> Void,
         onOversizedPaste: @escaping (String) -> Void,
         onRecallUp: (() -> Bool)? = nil,
         onRecallDown: (() -> Bool)? = nil,
         highlightsKeyword: Bool = false,
         onSuggestionKey: ((SuggestionKey) -> Bool)? = nil,
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
        self.onSuggestionKey = onSuggestionKey
        self.trailingAccessory = trailingAccessory()
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
                 onSuggestionKey: onSuggestionKey,
                 animatesKeyword: !reduceMotion,
                 onHeightChange: { height = $0 })
            .frame(height: min(max(height, line), line * CGFloat(maxLines)))
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
    let onSuggestionKey: ((SuggestionKey) -> Bool)?
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
        textView.isEditable = isEnabled
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor

        // Only ever claim focus, never clear it: handing it back to nobody would leave the
        // window with no first responder at all. Whatever the user moves to next takes it.
        if isFocused, isEnabled, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }

        textView.highlightsKeyword = highlightsKeyword
        textView.animatesKeyword = animatesKeyword
        // After the colour above, which is written into the text and takes the keyword's
        // own colours off it.
        textView.refreshKeyword()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextArea
        private var lastHeight: CGFloat = -1

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
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Only ever borrowed: with no suggestion to take, tab moves focus out of
                // the box the way it does in every other field.
                return suggestionKey(.edit)
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                // Escape arrives as cancelOperation:, which a text view turns into
                // complete: on the way, so both spellings are taken.
                return suggestionKey(.cancel)
            case #selector(NSResponder.moveUp(_:)):
                // Only the first line recalls, so a press in the middle of a prompt that
                // runs over several lines is always the cursor's. Whether an earlier
                // prompt should replace what is there at all is the runner's call, since
                // only it knows a walk is under way.
                if isOnFirstLine(textView), parent.onRecallUp?() == true { return true }
                return false
            case #selector(NSResponder.moveDown(_:)):
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

        // The thinking keyword, coloured where it sits so it is clear the word was taken
        // for more than text. The colours are temporary attributes, which live in the
        // layout manager rather than in the text, so the prompt itself stays plain and
        // typing around the word carries none of its colour.
        var highlightsKeyword = false
        var animatesKeyword = true
        private var keywordRanges: [NSRange] = []
        private var colouredRanges: [NSRange] = []
        private var sweep: Task<Void, Never>?
        private static let frameRate = Duration.milliseconds(42)

        // Whether the colours are moving, which is the one part of this that cannot be
        // read back off the attributes.
        var isSweeping: Bool { sweep != nil }

        // Called whenever the text or the settings around it change, since a keyword can
        // appear, move or stop being one with every keystroke.
        func refreshKeyword() {
            keywordRanges = highlightsKeyword ? ThinkingKeyword.ranges(in: string) : []

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
                        colourKeyword()
                    }
                }
            }
            colourKeyword()
        }

        private func colourKeyword() {
            guard let layoutManager else { return }

            let length = (string as NSString).length
            for range in colouredRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
            colouredRanges = keywordRanges

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
        }

        override func didChangeText() {
            super.didChangeText()
            refreshKeyword()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                sweep?.cancel()
                sweep = nil
            } else {
                refreshKeyword()
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
