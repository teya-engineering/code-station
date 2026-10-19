import AppKit
import SwiftUI
import CodeStationCore

// A task's prompt, written in place. Each {{hole}} is coloured as it is typed, so what a
// run will ask for is visible in the sentence that asks for it. The colour is a temporary
// attribute of the layout manager: the text itself stays plain, so selection, undo and
// VoiceOver all work on exactly what was typed.
//
// The view grows with its text instead of scrolling inside itself, since the page around
// it already scrolls and a second scroller in the middle of it would catch the wheel.
struct TaskPromptEditor: View {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 14.5
    var minHeight: CGFloat = 120
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var height: CGFloat = 0

    var body: some View {
        PromptTextView(text: $text, fontSize: fontSize,
                       onHeightChange: { height = $0 },
                       onFocusChange: onFocusChange)
            .frame(height: max(height, minHeight))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onHeightChange: (CGFloat) -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HoleTextView {
        let textView = HoleTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = .systemFont(ofSize: fontSize)
        textView.defaultParagraphStyle = Self.paragraph(for: fontSize)
        textView.typingAttributes[.paragraphStyle] = Self.paragraph(for: fontSize)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.setAccessibilityLabel("Prompt sent on every run")
        textView.string = text
        textView.applyParagraphStyle()
        textView.refreshHoles()
        return textView
    }

    func updateNSView(_ textView: HoleTextView, context: Context) {
        context.coordinator.parent = self
        // Only when the text moved on its own; writing back what was just typed would
        // drop the insertion point.
        if textView.string != text {
            textView.string = text
            textView.applyParagraphStyle()
            textView.refreshHoles()
            context.coordinator.reportHeight(of: textView)
        }
    }

    // Prompts are read as prose, so lines get a little more air than a field's.
    static func paragraph(for size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = round(size * 0.35)
        return style
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        private var lastHeight: CGFloat = -1

        init(_ parent: PromptTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(of: textView)
        }

        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            guard height != lastHeight else { return }
            lastHeight = height
            let report = parent.onHeightChange
            // Never during a layout pass: SwiftUI state cannot change while AppKit is
            // partway through laying the same view out.
            DispatchQueue.main.async { report(height) }
        }

        func reportFocus(_ focused: Bool) {
            let report = parent.onFocusChange
            // AppKit can move the first responder while SwiftUI is updating the view.
            DispatchQueue.main.async { report(focused) }
        }
    }

    final class HoleTextView: NSTextView {
        weak var coordinator: Coordinator?

        func applyParagraphStyle() {
            guard let storage = textStorage, let style = defaultParagraphStyle else { return }
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: NSRange(location: 0, length: storage.length))
        }

        func refreshHoles() {
            guard let layoutManager else { return }
            let whole = NSRange(location: 0, length: (string as NSString).length)
            // AppKit shifts temporary ranges as text is edited, so the old ones cannot
            // say where all the old colour is now.
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            for range in TaskTemplate.holeRanges(in: string) {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: Theme.accentNSColor,
                     .backgroundColor: Theme.accentNSColor.withAlphaComponent(0.11)],
                    forCharacterRange: range)
            }
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { coordinator?.reportFocus(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { coordinator?.reportFocus(false) }
            return accepted
        }

        override func didChangeText() {
            super.didChangeText()
            refreshHoles()
        }

        // SwiftUI sets the frame directly, so a new width arrives here rather than through
        // a layout pass, and the text has to be measured again at that width.
        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = newSize.width != frame.width
            super.setFrameSize(newSize)
            if widthChanged { coordinator?.reportHeight(of: self) }
        }

        override func layout() {
            super.layout()
            coordinator?.reportHeight(of: self)
        }
    }
}
