import AppKit
import CodeStationCore

// The GUI's half of "Open in": asking Launch Services which of the core's `OpenIn` apps
// are installed, drawing their icons, and opening a folder in one of them.
@MainActor
enum WorktreeOpener {
    // Asking Launch Services on every redraw of the header would be wasted work, so the
    // list is read once and again whenever the menu opens.
    private static var cached: [OpenInApp]?
    private static var icons: [URL: NSImage] = [:]

    static var apps: [OpenInApp] {
        if let cached { return cached }
        let found = installed()
        cached = found
        return found
    }

    static func refresh() {
        cached = installed()
    }

    static var current: OpenInApp? {
        OpenIn.current(from: apps)
    }

    static func icon(for app: OpenInApp) -> NSImage {
        if let icon = icons[app.url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 32, height: 32)
        icons[app.url] = icon
        return icon
    }

    static func open(_ path: String, in app: OpenInApp) {
        open(URL(fileURLWithPath: path, isDirectory: true), in: app)
    }

    static func open(_ folder: URL, in app: OpenInApp) {
        switch app.bundleID {
        case OpenIn.finderID:
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

    private static func installed() -> [OpenInApp] {
        let editors = OpenIn.editorIDs.compactMap(app(withBundleID:))
        let terminalURL = SystemTerminal.appURL
        let terminal = SystemTerminal.bundleID(of: terminalURL).map {
            OpenInApp(bundleID: $0, name: SystemTerminal.name(of: terminalURL), url: terminalURL)
        }
        return OpenIn.ordered(editors: editors, finder: app(withBundleID: OpenIn.finderID),
                              terminal: terminal)
    }

    private static func app(withBundleID id: String) -> OpenInApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        return OpenInApp(bundleID: id, name: SystemTerminal.name(of: url), url: url)
    }
}
