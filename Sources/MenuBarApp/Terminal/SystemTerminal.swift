import AppKit
import UniformTypeIdentifiers

// The terminal outside this app, for a shell in a window of its own rather than in the
// drawer. macOS has no setting for a preferred terminal, so the app that opens .command
// files stands in for it: that is Terminal until the user points it somewhere else.
enum SystemTerminal {
    private static let fallback = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    static var appURL: URL {
        guard let shellScript = UTType("com.apple.terminal.shell-script") else { return fallback }
        return NSWorkspace.shared.urlForApplication(toOpen: shellScript) ?? fallback
    }

    // Named in the menu, so the row says which app the click is about to raise.
    static var appName: String {
        FileManager.default.displayName(atPath: appURL.path)
    }

    static func open(_ directory: String) {
        guard !directory.isEmpty else { return }
        open(URL(fileURLWithPath: directory))
    }

    // Opening a folder on its own would just reveal it in Finder, so name the app.
    static func open(_ directory: URL) {
        NSWorkspace.shared.open([directory],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
