import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Fields

extension View {
    // The app's text field: no system chrome, a quiet fill and a hairline. Applied to a
    // TextField or a SecureField, so a form does not restate the recipe per field.
    func appTextField(size: CGFloat = 13, cornerRadius: CGFloat = 8) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: size))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .fieldSurface(cornerRadius: 10)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}
