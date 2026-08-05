import AppKit
import SwiftUI

// The prompt box. SwiftUI's vertical-axis TextField settles on a wrapping width early and
// never revisits it, so lines break far short of the box they are drawn in and the top of
// the text scrolls out of view instead of the box growing. An NSTextView wraps to the
// width it is actually given, grows with the text, and is also the only way to tell
// return-to-send apart from shift-return-for-a-newline.
struct ComposerField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    // Past this the box stops growing and the text scrolls inside it, so a long prompt
    // can never push the transcript off the screen.
    private let maxLines = 10
    private static let font = NSFont.systemFont(ofSize: 13)

    @State private var height: CGFloat = 0

    var body: some View {
        let line = ceil(Self.font.lineHeightForComposer)

        TextArea(text: $text,
                 isFocused: $isFocused,
                 isEnabled: isEnabled,
                 font: Self.font,
                 onSubmit: onSubmit,
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

private extension NSFont {
    // The height one line of this font occupies once laid out, which is what the box has
    // to be a multiple of.
    var lineHeightForComposer: CGFloat { ascender - descender + leading }
}

private struct TextArea: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let font: NSFont
    let onSubmit: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = font
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
        textView.string = text

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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorView else { return }
        context.coordinator.parent = self

        // Only when the model moved on its own, e.g. the draft cleared after a send.
        // Writing back what the user just typed would drop the insertion point.
        if textView.string != text {
            textView.string = text
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
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextArea
        private var lastHeight: CGFloat = -1

        init(_ parent: TextArea) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(of: textView)
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
            default:
                return false
            }
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
