import Foundation

// Where the app keeps what it owns. macOS gives an app more than one home and they are
// not interchangeable: data the app manages lives in Application Support, secrets live in
// the Keychain, and small preferences live in UserDefaults.
enum AppPaths {
    // Bundle.main has no identifier when the binary is run straight from the build folder,
    // which is how the app runs in development.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.teya.code-station"

    // The identifier the app answered to before it was renamed. Everything the app owns is
    // filed under the identifier - the data folder, the logs, the preferences and the
    // Keychain items - so the old one has to stay readable or an upgrade looks like a
    // fresh install. Keychain.swift reads it for the same reason.
    static let previousBundleID = "com.teya.conductor"

    // Tests run this same code in a process that has no bundle, so left alone they would
    // file under the app's own identifier and work in the folders of the app the developer
    // is using. A test process gets a root of its own instead, and adopts nothing.
    static let isTestProcess: Bool = {
        let process = ProcessInfo.processInfo
        return Bundle.main.bundleURL.pathExtension == "xctest"
            || process.arguments.contains { $0.contains(".xctest/") }
            || process.processName == "xctest"
            || process.processName.hasSuffix("PackageTests")
            || process.environment["XCTestConfigurationFilePath"] != nil
    }()

    private static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(bundleID)-tests-\(getpid())")

    private static var supportBase: URL {
        if isTestProcess { return testRoot.appendingPathComponent("Application Support") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
    }

    static var support: URL {
        _ = adoptedPreviousBundle
        return supportBase.appendingPathComponent(bundleID)
    }

    // Carries what the old identifier owns over to the new one. A `static let` runs once
    // per launch and before any path below is handed out, so nothing has been created
    // under the new name yet and the moves below still see an empty destination.
    private static let adoptedPreviousBundle: Void = {
        guard bundleID != previousBundleID, !isTestProcess else { return }
        move(supportBase.appendingPathComponent(previousBundleID),
             to: supportBase.appendingPathComponent(bundleID))
        move(logsBase.appendingPathComponent(previousBundleID),
             to: logsBase.appendingPathComponent(bundleID))
        adoptDefaults(of: previousBundleID)
    }()

    // Preferences live in a domain named after the bundle, so the renamed app would start
    // with none of the choices the user made. A key already answered here wins, so this
    // can never undo a newer answer, and the marker keeps a later launch from reviving a
    // preference the user has since cleared.
    static func adoptDefaults(of domain: String, into store: UserDefaults = .standard) {
        let marker = "adoptedDefaultsFrom-\(domain)"
        guard !store.bool(forKey: marker) else { return }
        store.set(true, forKey: marker)
        guard let previous = store.persistentDomain(forName: domain) else { return }
        for (key, value) in previous where store.object(forKey: key) == nil {
            store.set(value, forKey: key)
        }
    }

    // A file the app owns, moved out of the directory an earlier version used if it is
    // still sitting there. Without the move, an upgrade would look like a fresh install.
    static func supportFile(_ name: String, movedFrom legacy: URL? = nil) -> URL {
        let url = support.appendingPathComponent(name)
        if let legacy { move(legacy, to: url) }
        return url
    }

    static func supportFile(_ name: String, moving candidates: [URL]) -> URL {
        let url = support.appendingPathComponent(name)
        move(candidates, to: url)
        return url
    }

    static func move(_ candidates: [URL], to url: URL) {
        for candidate in candidates { move(candidate, to: url) }
    }

    static func move(_ legacy: URL, to url: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: url.path) else { return }
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: legacy, to: url)
    }

    // Where an earlier version kept everything, in the XDG style. The name is the one that
    // release wrote, so it stays as it is however the app is called now.
    static func legacy(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-conductor/\(name)")
    }

    // Logs go where macOS keeps logs rather than in Application Support, so Console and
    // the usual "collect the logs" habits find them without being told where to look.
    static var logs: URL {
        _ = adoptedPreviousBundle
        let url = logsBase.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var logsBase: URL {
        if isTestProcess { return testRoot.appendingPathComponent("Logs") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    }

    // Creates an app-owned folder and optionally keeps reproducible or short-lived data
    // out of backups. The caller chooses whether that folder belongs under support or in
    // another app-owned location.
    static func directory(_ name: String, backedUp: Bool = true) -> URL {
        let url = support.appendingPathComponent(name)
        return directory(at: url, backedUp: backedUp)
    }

    static func directory(at url: URL, backedUp: Bool = true) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !backedUp {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        return url
    }
}
