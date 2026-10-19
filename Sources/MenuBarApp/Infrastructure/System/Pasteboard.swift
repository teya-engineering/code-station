import AppKit
import CodeStationCore

// Clipboard writes are kept together so text and files both replace the old contents
// before advertising the types other Mac apps expect. The GUI host copies through here,
// and so do the GUI's own copy buttons.
enum Pasteboard {
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func copy(_ file: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    static func copy(imageAt file: URL, to pasteboard: NSPasteboard = .general) {
        copy(ClipboardContent.image(at: file) ?? .image(png: Data(), file: file),
             to: pasteboard)
    }

    // An image goes out as both the picture and the file it came from, on one item, so an
    // app that takes pixels and one that takes a file each find what they want.
    static func copy(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) {
        switch content {
        case .text(let text):
            copy(text, to: pasteboard)
        case .file(let file):
            copy(file, to: pasteboard)
        case .image(let png, let file):
            let item = NSPasteboardItem()
            if let file { item.setString(file.absoluteString, forType: .fileURL) }
            if !png.isEmpty { item.setData(png, forType: .png) }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
