import AppKit
import UniformTypeIdentifiers

// Clipboard writes are kept together so text and files both replace the old contents
// before advertising the types other Mac apps expect.
enum Pasteboard {
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copy(_ file: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    // An image goes out as both the picture and the file it came from, on one item, so an
    // app that takes pixels and one that takes a file each find what they want.
    static func copy(imageAt file: URL, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let png = pngBytes(of: file) { item.setData(png, forType: .png) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    // Apps take a picture off the clipboard as PNG, so a file saved in anything else is
    // re-encoded. The bytes are read from disk rather than from what is drawn, which is
    // only a reduced copy.
    private static func pngBytes(of file: URL) -> Data? {
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.pathExtension)
        if type == .png { return try? Data(contentsOf: file) }
        guard let image = NSImage(contentsOf: file),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
