import AppKit
import UniformTypeIdentifiers

// The terminal outside this app, for a shell in a window of its own rather than in the
// drawer. macOS has no setting for a preferred terminal, so the app takes the one chosen
// in settings, and without a choice falls back to the app that opens .command files: that
// is Terminal until the user points it somewhere else.
enum SystemTerminal {
    static let fallback = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    private static var shellScript: UTType? { UTType("com.apple.terminal.shell-script") }

    // What macOS hands a .command file. Nobody sets this on purpose, so it is a starting
    // point rather than an answer.
    static var systemDefault: URL {
        guard let shellScript else { return fallback }
        return NSWorkspace.shared.urlForApplication(toOpen: shellScript) ?? fallback
    }

    static var appURL: URL {
        chosen ?? systemDefault
    }

    // A bundle ID that no longer resolves means the app was removed, and the fallback takes
    // over rather than the click doing nothing.
    static var chosen: URL? {
        guard let id = Preferences.terminalBundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    // Named in the menu, so the row says which app the click is about to raise.
    static var appName: String {
        name(of: appURL)
    }

    static func name(of url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    static func bundleID(of url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    // Every app macOS says can open a shell script, narrowed to the ones that would run it.
    // The role is what separates a terminal from an editor: plenty of apps open a .command
    // file to show its text, and they claim the type just as loudly as a terminal does.
    static var installed: [URL] {
        guard let shellScript else { return [fallback] }
        let claimants = NSWorkspace.shared.urlsForApplications(toOpen: shellScript)

        var seen = Set<String>()
        var terminals: [URL] = []
        for url in [systemDefault, chosen].compactMap(\.self) + claimants {
            guard let id = bundleID(of: url) else { continue }
            guard seen.insert(id).inserted else { continue }
            // The system default and the current choice are listed whatever they declare,
            // so a terminal the check misses is still visible once it has been picked.
            let isPreferred = url == systemDefault || url == chosen
            guard isPreferred || runsShellScripts(url) else { continue }
            // The same app can be registered from more than one copy on disk, and the
            // staged copies an installer leaves behind are not the one to launch.
            terminals.append(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) ?? url)
        }
        return terminals.sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
    }

    static func runsShellScripts(_ url: URL) -> Bool {
        let types = Bundle(url: url)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]
        return types?.contains { $0["CFBundleTypeRole"] as? String == "Shell" } ?? false
    }

    static func open(_ directory: String) {
        guard !directory.isEmpty else { return }
        open(URL(fileURLWithPath: directory))
    }

    // Opening a folder on its own would just reveal it in Finder, so name the app.
    static func open(_ directory: URL) {
        let app = appURL
        NSWorkspace.shared.open([directory],
                                withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            // Not every terminal claims to open a folder, and the ones that do not would
            // leave the click doing nothing at all. A window in the wrong directory is
            // still a window the user asked for.
            guard error != nil else { return }
            NSWorkspace.shared.openApplication(at: app,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
