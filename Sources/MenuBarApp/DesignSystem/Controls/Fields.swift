import AppKit
import SwiftUI

// MARK: - Fields

extension View {
    // The app's text field: no system chrome, a quiet fill and a hairline. Applied to a
    // TextField or a SecureField, so a form does not restate the recipe per field.
    func appTextField(size: CGFloat = Typography.Size.body,
                      cornerRadius: CGFloat = Radius.control) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: size))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .fieldSurface(cornerRadius: cornerRadius)
    }

    // Shows a cursor while the pointer is over the view and puts the old one back when
    // it leaves, for a control sitting on a strip that shows a cursor of its own.
    func cursorOnHover(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// The multi-line field, with the placeholder drawn over it because TextEditor has none
// of its own. The placeholder takes no clicks, so the first click still lands in the
// editor.
struct AppTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80

    init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 80) {
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .frame(minHeight: minHeight)
            .fieldSurface(cornerRadius: Radius.card)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typography.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                        .allowsHitTesting(false)
                }
            }
    }
}
