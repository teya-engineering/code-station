import AppKit
import SwiftUI

@MainActor
enum FolderActions {
    static func entries(for path: String, openShell: OpenShell,
                        note: ExternalNote) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let app = WorktreeOpener.current {
            entries.append(.item("Open in \(app.name)", image: WorktreeOpener.icon(for: app),
                                 imageShape: .tile) {
                open(path, in: app, note: note)
            })
        }
        entries.append(.item("Reveal in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            note("Shown in Finder", "arrow.up.forward.app")
        })
        if let run = openShell.run {
            entries.append(.item("Terminal here", icon: "terminal") { run(path) })
        }
        entries.append(copyPath(path, note: note))

        return entries
    }

    static func open(_ path: String, in app: WorktreeApp, note: ExternalNote) {
        WorktreeOpener.open(path, in: app)
        note("Opened the folder in \(app.name)", "arrow.up.forward.app")
    }

    static func copyPath(_ path: String, note: ExternalNote) -> MenuEntry {
        .item("Copy path", icon: "doc.on.doc") {
            Pasteboard.copy(path)
            note("Copied the folder path", "doc.on.doc")
        }
    }
}

// Closures cannot be compared, so every copy counts as equal.
struct OpenShell: Equatable {
    var run: ((_ directory: String) -> Void)?

    static func == (_: OpenShell, _: OpenShell) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var openShell = OpenShell()
}
