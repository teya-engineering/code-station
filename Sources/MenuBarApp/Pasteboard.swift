import AppKit

// The one way text leaves the app for the clipboard, so every copy button clears the
// old contents the same way before writing.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
