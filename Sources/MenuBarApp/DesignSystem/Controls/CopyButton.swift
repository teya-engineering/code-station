import AppKit
import SwiftUI

// MARK: - Copy

// Puts text on the clipboard and says so for a moment. The text is asked for at the
// click, so the button can sit beside a value that is still being edited.
struct CopyButton: View {
    let title: String?
    var size: CGFloat = Typography.Size.caption
    // For a caller that marks the copy on what was copied, as well as on the button.
    var onCopy: (() -> Void)? = nil
    let text: () -> String

    init(_ title: String? = nil, size: CGFloat = Typography.Size.caption, onCopy: (() -> Void)? = nil,
         text: @escaping () -> String) {
        self.title = title
        self.size = size
        self.onCopy = onCopy
        self.text = text
    }

    // Long enough to be seen, short enough that the button is ready for the next value
    // by the time the pointer moves on.
    private static let confirmation = Duration.milliseconds(1_500)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            Pasteboard.copy(text())
            copied = true
            onCopy?()
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: Self.confirmation)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: size, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                if let title {
                    Text(copied ? "Copied" : title)
                        .font(.system(size: size, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(copied ? Theme.addition : Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .motion(Motion.pop, value: copied)
    }
}
