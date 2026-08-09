import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// A file that goes out with a prompt. Claude Code takes files by path, so anything that
// arrives as raw bytes - a screenshot on the clipboard - has to be written to disk
// before the turn can start.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var isImage: Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }
}

enum Attachments {
    // Pasted files only matter for as long as the conversation does, so they stay out of
    // backups and are removed after old conversations have had time to resume.
    static var folder: URL { AppPaths.directory("attachments", backedUp: false) }

    // What the clipboard holds, if it is worth attaching. Files win over images:
    // copying a file in Finder also puts its name on the clipboard as text and a
    // preview of it as an image, and the file itself is what was meant.
    static func fromClipboard(_ pasteboard: NSPasteboard = .general) -> [Attachment] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return urls.map { Attachment(url: $0) }
        }
        // Apps that copy text often put a picture of it on the clipboard as well -
        // spreadsheet cells arrive as both. Text is what was meant there, so an image
        // only counts when it comes on its own.
        guard pasteboard.string(forType: .string) == nil,
              let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let file = write(image) else { return [] }
        return [Attachment(url: file)]
    }

    static func fromDrop(_ urls: [URL]) -> [Attachment] {
        urls.filter(\.isFileURL).map { Attachment(url: $0) }
    }

    static func fromPastedText(_ text: String) -> Attachment? {
        let name = "pasted-text-\(UUID().uuidString.prefix(8)).txt"
        let url = folder.appendingPathComponent(name)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return Attachment(url: url)
    }

    // A clipboard image arrives as whatever format the app that copied it used, so it is
    // re-encoded as PNG under a name of our own.
    private static func write(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    // A pasted file is referenced by path in a conversation that can be resumed later,
    // so it has to outlive the turn that sent it. A week is long enough for that and
    // short enough that the folder does not grow forever.
    static func pruneOldPastes(olderThan days: Int = 7) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let contents = (try? files.contentsOfDirectory(at: folder,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: .skipsHiddenFiles)) ?? []
        for file in contents {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? files.removeItem(at: file) }
        }
    }
}

// MARK: - Pasting into the composer

// SwiftUI's onPasteCommand never fires while a text field has the keyboard: the field
// claims paste: whatever the clipboard holds and quietly drops what it cannot read as
// text. Nor is a view's own key handling early enough - Edit's Paste item runs first, and
// a file copied in Finder puts its name on the clipboard as text too, so the menu would
// take the shortcut and paste that name. A monitor sees the key before either of them.
private struct PasteCatcher: ViewModifier {
    let isEnabled: Bool
    let onPaste: ([Attachment]) -> Void

    @State private var monitor = Monitor()

    func body(content: Content) -> some View {
        content
            .onChange(of: isEnabled, initial: true) { _, enabled in
                if enabled { monitor.start(onPaste) } else { monitor.stop() }
            }
            .onDisappear { monitor.stop() }
    }

    // The handler runs outside the main actor, so what it needs lives in a class it can
    // hold rather than in the view value it was created from.
    @MainActor
    final class Monitor {
        private var token: Any?
        private var onPaste: (([Attachment]) -> Void)?

        func start(_ onPaste: @escaping ([Attachment]) -> Void) {
            // Kept on the monitor rather than captured by the handler: the view is a
            // value that is made again on every redraw, and the handler is registered once.
            self.onPaste = onPaste
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Nothing about the event itself is carried across: it stays here, and
                // only the answer to "was this a paste" goes to the main actor.
                let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                    && event.charactersIgnoringModifiers?.lowercased() == "v"
                guard isPaste else { return event }
                // Swallowed only when something was attached; plain text still belongs to
                // the text field.
                return MainActor.assumeIsolated { self.take() } ? nil : event
            }
        }

        private func take() -> Bool {
            // A sheet is its own window with its own fields, and their paste is not ours.
            guard let onPaste, NSApp.keyWindow?.attachedSheet == nil else { return false }
            let found = Attachments.fromClipboard()
            guard !found.isEmpty else { return false }
            onPaste(found)
            return true
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            onPaste = nil
        }
    }
}

extension View {
    func pasteAttachments(enabled: Bool, onPaste: @escaping ([Attachment]) -> Void) -> some View {
        modifier(PasteCatcher(isEnabled: enabled, onPaste: onPaste))
    }
}

// MARK: - Showing one

// A file on its way out, or one that already went. Images show a thumbnail, everything
// else shows an icon and its name. `onRemove` is what makes it a composer chip rather
// than a record of what was sent.
struct AttachmentChip: View {
    let url: URL
    var onRemove: (() -> Void)?

    @State private var preview: Image?

    var body: some View {
        HStack(spacing: 6) {
            if let preview {
                preview
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: missing ? "questionmark.square.dashed" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(missing ? Color.secondary : Color.primary)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .frame(maxWidth: 220)
        .help(url.path)
        .task(id: url) {
            let thumbnail = await Task.detached(priority: .utility) {
                Self.thumbnail(url)
            }.value
            guard !Task.isCancelled else { return }
            preview = thumbnail.map { Image(decorative: $0.image, scale: 1) }
        }
    }

    private var missing: Bool { !FileManager.default.fileExists(atPath: url.path) }

    // Screenshots are large, so the chip decodes a small copy instead of the whole image.
    private nonisolated static func thumbnail(_ url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
              ] as CFDictionary) else { return nil }
        return Thumbnail(image: image)
    }

    private struct Thumbnail: @unchecked Sendable {
        let image: CGImage
    }
}
