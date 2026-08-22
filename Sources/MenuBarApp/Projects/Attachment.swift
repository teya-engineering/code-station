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
            .background(PasteWindowAnchor(monitor: monitor))
            .onChange(of: isEnabled, initial: true) { _, enabled in
                if enabled { monitor.start(onPaste) } else { monitor.stop() }
            }
            .onDisappear { monitor.stop() }
    }

    // The handler runs outside the main actor, so what it needs lives in a class it can
    // hold rather than in the view value it was created from.
    @MainActor
    final class Monitor {
        // Says which window the box is in. A monitor sees every key press in the app, so
        // this is what tells one box's paste from another's.
        weak var anchor: NSView?

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
            // Every box that accepts a pasted file has a monitor of its own and they all
            // see the key press, so only the one in front acts on it. A box left focused
            // behind a sheet must not answer for the sheet's own.
            guard let onPaste, let window = anchor?.window,
                  window === Self.frontmostWindow else { return false }
            let found = Attachments.fromClipboard()
            guard !found.isEmpty else { return false }
            onPaste(found)
            return true
        }

        // Which of a sheet and the window it hangs off counts as key is not worth relying
        // on, so the chain is followed to whichever sheet ended up on top.
        private static var frontmostWindow: NSWindow? {
            var window = NSApp.keyWindow
            while let sheet = window?.attachedSheet { window = sheet }
            return window
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            onPaste = nil
        }
    }
}

private struct PasteWindowAnchor: NSViewRepresentable {
    let monitor: PasteCatcher.Monitor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        monitor.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { monitor.anchor = view }

    // Only there to name a window, so it takes no clicks of its own.
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func pasteAttachments(enabled: Bool, onPaste: @escaping ([Attachment]) -> Void) -> some View {
        modifier(PasteCatcher(isEnabled: enabled, onPaste: onPaste))
    }
}

// MARK: - Showing one

// A small decoded copy of an image file. Screenshots are large, so anything that
// draws one decodes a bounded copy instead of the whole image.
struct ImageThumbnail: @unchecked Sendable {
    let image: CGImage

    var aspectRatio: CGFloat { CGFloat(image.width) / CGFloat(image.height) }

    nonisolated static func load(_ url: URL, maxPixelSize: Int) -> ImageThumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return ImageThumbnail(image: image)
    }
}

// A file on its way out, or one that already went. Images show a thumbnail, everything
// else shows an icon and its name. `onRemove` is what makes it a composer chip rather
// than a record of what was sent.
struct AttachmentChip: View {
    @Environment(DialogPresenter.self) private var dialogs

    let url: URL
    var onRemove: (() -> Void)?

    @State private var thumbnail: ImageThumbnail?

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Button {
                    showPreview(aspectRatio: thumbnail.aspectRatio)
                } label: {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .appTooltip("View full image")
                .accessibilityLabel("View \(url.lastPathComponent)")
            } else {
                Image(systemName: missing ? "questionmark.square.dashed" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            // The name is what gets truncated, so it is also what answers where the file
            // came from. The hint sits on the name rather than on the whole pill, so it
            // does not fight the buttons on either side of it for the pointer.
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(missing ? Color.secondary : Color.primary)
                .appTooltip { Tooltip(title: url.lastPathComponent, subtitle: url.path) }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .appTooltip("Remove")
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .frame(maxWidth: 220)
        .task(id: url) {
            let thumbnail = await Task.detached(priority: .utility) {
                ImageThumbnail.load(url, maxPixelSize: 96)
            }.value
            guard !Task.isCancelled else { return }
            self.thumbnail = thumbnail
        }
    }

    private var missing: Bool { !FileManager.default.fileExists(atPath: url.path) }

    private func showPreview(aspectRatio: CGFloat) {
        dialogs.show(Dialog(
            title: url.lastPathComponent,
            content: AnyView(AttachmentImagePreview(url: url, aspectRatio: aspectRatio)),
            actions: [.init(label: "Close", kind: .cancel)],
            width: 760))
    }
}

// An image shown at reading size in the transcript, with a click opening the full
// preview. A file that decodes to nothing falls back to the plain chip, so a broken
// image still says which file it was.
struct InlineImageView: View {
    @Environment(DialogPresenter.self) private var dialogs

    let url: URL
    var label: String?
    var maximumWidth: CGFloat = 280

    @State private var thumbnail: ImageThumbnail?
    @State private var failed = false

    private static let maxHeight: CGFloat = 200

    var body: some View {
        Group {
            if let thumbnail {
                let size = fit(thumbnail)
                Button {
                    showPreview(aspectRatio: thumbnail.aspectRatio)
                } label: {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .appTooltip { Tooltip(title: label ?? url.lastPathComponent, subtitle: url.path) }
                .accessibilityLabel("View \(label ?? url.lastPathComponent)")
            } else if failed {
                AttachmentChip(url: url)
            } else {
                // A quiet stand-in close to the finished size, so the page settles
                // instead of jumping when the decode lands.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.sunken)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: min(220, maximumWidth),
                           height: min(140, maximumWidth / 220 * 140))
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) {
                // Twice the widest it can draw, so it stays sharp on a Retina display
                // without decoding a screenshot at full size.
                ImageThumbnail.load(url, maxPixelSize: 640)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = loaded
            failed = loaded == nil
        }
    }

    // Fits the reading box without blowing a small image up past its own pixels.
    private func fit(_ thumbnail: ImageThumbnail) -> CGSize {
        let width = min(maximumWidth, Self.maxHeight * thumbnail.aspectRatio,
                        CGFloat(thumbnail.image.width))
        return CGSize(width: width, height: width / thumbnail.aspectRatio)
    }

    private func showPreview(aspectRatio: CGFloat) {
        dialogs.show(Dialog(
            title: url.lastPathComponent,
            content: AnyView(AttachmentImagePreview(url: url, aspectRatio: aspectRatio)),
            actions: [.init(label: "Close", kind: .cancel)],
            width: 760))
    }
}

private struct AttachmentImagePreview: View {
    let url: URL
    let aspectRatio: CGFloat

    @State private var image: ImageThumbnail?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.sunken)

            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 24, weight: .light))
                    Text("This image could not be loaded.")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .task(id: url) {
            // The popup is at most 720 points wide. A 1,440-pixel copy remains sharp on
            // a Retina display without decoding a large screenshot at its full size.
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageThumbnail.load(url, maxPixelSize: 1_440)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }

    private var previewHeight: CGFloat {
        min(480, max(180, 720 / aspectRatio))
    }
}
