import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorSaveError: View {
    let message: String
    let retry: () -> Void
    let export: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label("Could not save. Your edits are still here.", systemImage: "exclamationmark.triangle")
            Text(message).font(Typography.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                InlineLink(title: "Retry", action: retry)
                InlineLink(title: "Export a copy", action: export)
            }
        }.font(Typography.detail).foregroundStyle(Theme.deletion).padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading).background(Theme.deletion.opacity(0.06))
    }
}

@MainActor func announceEditorStatus(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
}

@MainActor func exportMarkdown(_ source: String, name: String, dialogs: DialogPresenter, notify: @escaping (String) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    guard let window = WindowKeyMonitor.frontmostWindow else { return }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        do { try source.write(to: url, atomically: true, encoding: .utf8); notify("Markdown copy exported") }
        catch { dialogs.show(.notice("Could not export", message: error.localizedDescription)) }
    }
}
