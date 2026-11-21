import AppKit

// An app a session's folder can be opened in from the header.
struct WorktreeApp: Equatable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }
}

// Where "Open in" sends a session's folder: the code editors on this Mac, Finder, and the
// chosen terminal. The last app picked is remembered, so the main half of the button does
// the same thing every time until someone picks another.
@MainActor
enum WorktreeOpener {
    static let finderID = "com.apple.finder"

    // Editors that open a folder as a project. Only the ones installed are offered.
    static let editorIDs = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
    ]

    // Asking Launch Services on every redraw of the header would be wasted work, so the
    // list is read once and again whenever the menu opens.
    private static var cached: [WorktreeApp]?
    private static var icons: [URL: NSImage] = [:]

    static var apps: [WorktreeApp] {
        if let cached { return cached }
        let found = installed()
        cached = found
        return found
    }

    static func refresh() {
        cached = installed()
    }

    static var current: WorktreeApp? {
        chosen(from: apps, saved: Preferences.openInBundleID)
    }

    // An app that has been removed since it was picked falls back to Finder, which every
    // Mac has, so the button never points at nothing.
    static func chosen(from apps: [WorktreeApp], saved: String?) -> WorktreeApp? {
        apps.first { $0.bundleID == saved }
            ?? apps.first { $0.bundleID == finderID }
            ?? apps.first
    }

    // Editors first, then Finder, then the terminal. An app that turns up twice, such as a
    // terminal that is also listed as an editor, is only offered once.
    static func ordered(editors: [WorktreeApp], finder: WorktreeApp?,
                        terminal: WorktreeApp?) -> [WorktreeApp] {
        var seen = Set<String>()
        return (editors + [finder, terminal].compactMap(\.self))
            .filter { seen.insert($0.bundleID).inserted }
    }

    static func icon(for app: WorktreeApp) -> NSImage {
        if let icon = icons[app.url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 32, height: 32)
        icons[app.url] = icon
        return icon
    }

    static func choose(_ app: WorktreeApp) {
        Preferences.openInBundleID = app.bundleID
    }

    static func open(_ path: String, in app: WorktreeApp) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        switch app.bundleID {
        case finderID:
            NSWorkspace.shared.open(folder)
        case SystemTerminal.bundleID(of: SystemTerminal.appURL):
            // The terminal has its own way in, which still opens a window when the app
            // does not claim folders.
            SystemTerminal.open(folder)
        default:
            NSWorkspace.shared.open([folder], withApplicationAt: app.url,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func installed() -> [WorktreeApp] {
        let editors = editorIDs.compactMap(app(withBundleID:))
        let terminalURL = SystemTerminal.appURL
        let terminal = SystemTerminal.bundleID(of: terminalURL).map {
            WorktreeApp(bundleID: $0, name: SystemTerminal.name(of: terminalURL), url: terminalURL)
        }
        return ordered(editors: editors, finder: app(withBundleID: finderID), terminal: terminal)
    }

    private static func app(withBundleID id: String) -> WorktreeApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        return WorktreeApp(bundleID: id, name: SystemTerminal.name(of: url), url: url)
    }
}
