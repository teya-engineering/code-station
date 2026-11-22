import AppKit

// An app a session's folder can be opened in from the header.
struct WorktreeApp: Equatable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }
}

// Where "Open in" sends a session's folder: the code editors on this Mac, the apps the
// person added, Finder, and the chosen terminal. The last app picked is remembered, so the
// main half of the button does the same thing every time until someone picks another.
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
        "com.jetbrains.goland",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.rustrover",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rubymine",
        "com.jetbrains.CLion",
        "com.jetbrains.datagrip",
        "com.jetbrains.rider",
        "com.google.android.studio",
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
        chosen(from: apps, saved: Preferences.openInBundleID())
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
        Preferences.setOpenInBundleID(app.bundleID)
    }

    static var addedApps: [WorktreeApp] {
        let added = Set(Preferences.openInAddedBundleIDs())

        return apps.filter { added.contains($0.bundleID) }
    }

    @discardableResult
    static func add(appAt url: URL) -> WorktreeApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let added = Preferences.openInAddedBundleIDs()
        if !apps.contains(where: { $0.bundleID == id }) || added.contains(id) {
            if !added.contains(id) { Preferences.setOpenInAddedBundleIDs(added + [id]) }
            var paths = Preferences.openInAddedAppPaths()
            paths[id] = url.path
            Preferences.setOpenInAddedAppPaths(paths)
        }
        refresh()
        Preferences.setOpenInBundleID(id)

        return apps.first { $0.bundleID == id }
    }

    static func pickApp(dialogs: DialogPresenter) -> WorktreeApp? {
        guard let url = FilePicker.chooseFile(prompt: "Add",
                                              message: "Pick an app to open folders in.",
                                              types: [.application],
                                              directory: URL(fileURLWithPath: "/Applications"))
        else { return nil }
        guard let app = add(appAt: url) else {
            dialogs.show(.notice(
                "Could not use that app",
                message: "\(SystemTerminal.name(of: url)) does not look like an application macOS can open."))
            return nil
        }

        return app
    }

    static func remove(_ bundleID: String) {
        Preferences.setOpenInAddedBundleIDs(Preferences.openInAddedBundleIDs().filter { $0 != bundleID })
        var paths = Preferences.openInAddedAppPaths()
        paths.removeValue(forKey: bundleID)
        Preferences.setOpenInAddedAppPaths(paths)
        if Preferences.openInBundleID() == bundleID {
            Preferences.setOpenInBundleID(nil)
        }
        refresh()
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
        let editors = (editorIDs + Preferences.openInAddedBundleIDs()).compactMap(app(withBundleID:))
        let terminalURL = SystemTerminal.appURL
        let terminal = SystemTerminal.bundleID(of: terminalURL).map {
            WorktreeApp(bundleID: $0, name: SystemTerminal.name(of: terminalURL), url: terminalURL)
        }
        return ordered(editors: editors, finder: app(withBundleID: finderID), terminal: terminal)
    }

    private static func app(withBundleID id: String) -> WorktreeApp? {
        // A picked app may not be registered with macOS. Keep its path so the choice
        // survives a restart, and use Launch Services if it has since moved.
        if let path = Preferences.openInAddedAppPaths()[id],
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if SystemTerminal.bundleID(of: url) == id {
                return WorktreeApp(bundleID: id, name: SystemTerminal.name(of: url), url: url)
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        return WorktreeApp(bundleID: id, name: SystemTerminal.name(of: url), url: url)
    }
}
