import AppKit
import ImageIO
import SwiftUI

struct NoteAttachmentTile: View {
    @Environment(NotebookStore.self) private var store
    let attachment: NoteAttachment
    let preview: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: preview) {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(height: 90).clipped().accessibilityHidden(true)
                }
                HStack(spacing: 9) {
                    Image(systemName: attachment.image ? "photo" : "doc")
                        .font(.system(size: 17)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(attachment.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).hoverLift()
        .accessibilityLabel("Preview \(attachment.name)")
        .task(id: attachment.id) {
            guard attachment.image else { return }
            let url = store.attachmentURL(attachment)
            let thumbnail = await Task.detached { NoteImage.thumbnail(url, size: 520) }.value
            if let thumbnail { image = NSImage(cgImage: thumbnail, size: .zero) }
        }
    }
}

enum NoteImage {
    static func thumbnail(_ url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ] as CFDictionary)
    }
}

struct NoteAttachmentPreview: View {
    let attachment: NoteAttachment
    let url: URL
    let close: () -> Void
    let restoreFocus: () -> Void
    @State private var image: NSImage?
    @State private var text: String?
    @State private var loading = true
    @State private var error: String?
    @State private var saved = false
    @State private var noteTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field: Hashable { case close, save }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(attachment.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer()
                GlyphButton(icon: "xmark", side: 30, action: close)
                    .accessibilityLabel("Close attachment preview").keyboardShortcut(.cancelAction)
                    .focused($focused, equals: .close)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == .close ? Theme.accent : .clear, lineWidth: 2))
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 400)
                        .accessibilityLabel(attachment.name)
                } else if let text {
                    ScrollView { Text(text).font(.mono(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                        .frame(height: 330)
                } else {
                    PaneMessage(icon: attachment.image ? "photo" : "doc",
                                title: loading ? "Loading attachment…" : error == nil ? "Preview isn’t available" : "Couldn’t load attachment",
                                detail: error ?? "Save a copy to open it on your Mac.")
                        .frame(minHeight: 160)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            if let error { WarningStrip(error, icon: "exclamationmark.triangle") }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ActionButton(title: "Save a copy", tone: .outlined, icon: "square.and.arrow.down", action: download)
                    .focused($focused, equals: .save)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == .save ? Theme.accent : .clear, lineWidth: 2))
            }
            if saved { HeaderNote(icon: "checkmark", text: "Attachment copy saved").transition(.popover(reduceMotion: reduceMotion)) }
        }
        .padding(22).background(Theme.card)
        .onKeyPress(keys: [.tab]) { _ in
            focused = focused == .close ? .save : .close
            return .handled
        }
        .onAppear { focused = .close }
        .motion(Motion.reveal, value: saved)
        .task {
            if attachment.image {
                let result = await Task.detached { NoteImage.thumbnail(url, size: 1600) }.value
                if let result { image = NSImage(cgImage: result, size: .zero) }
            } else {
                do {
                    // Preview a bounded prefix; copying the attachment always keeps the full file.
                    text = try await Task.detached {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 256 * 1024) ?? Data()
                        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil as String? }
                        return text + (attachment.byteCount > 256 * 1024 ? "\n\n[Preview truncated. Save a copy for the full file.]" : "")
                    }.value
                } catch { self.error = error.localizedDescription }
            }
            if !FileManager.default.fileExists(atPath: url.path) { error = "The stored file is missing." }
            loading = false
        }
        .onDisappear { noteTask?.cancel(); restoreFocus() }
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        guard let window = WindowKeyMonitor.frontmostWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached {
                        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try FileManager.default.copyItem(at: url, to: temporary)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                    }.value
                    saved = true
                    noteTask?.cancel()
                    noteTask = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        saved = false
                    }
                } catch { self.error = "Couldn’t save a copy: \(error.localizedDescription)" }
            }
        }
    }
}
