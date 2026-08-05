import Foundation

// Where the app keeps what it owns. macOS gives an app more than one home and they are
// not interchangeable: data the app manages lives in Application Support, secrets live in
// the Keychain, and small preferences live in UserDefaults.
enum AppPaths {
    // Bundle.main has no identifier when the binary is run straight from the build folder,
    // which is how the app runs in development.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.teya.conductor"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID)
    }

    // A file the app owns, moved out of the directory an earlier version used if it is
    // still sitting there. Without the move, an upgrade would look like a fresh install.
    static func supportFile(_ name: String, movedFrom legacy: URL? = nil) -> URL {
        let url = support.appendingPathComponent(name)
        if let legacy { move(legacy, to: url) }
        return url
    }

    static func move(_ legacy: URL, to url: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: url.path) else { return }
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: legacy, to: url)
    }

    // Where an earlier version kept everything, in the XDG style.
    static func legacy(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-conductor/\(name)")
    }

    // Worktrees are git checkouts holding work that is not committed yet, so they cannot
    // live in Caches where the system is free to reclaim them. They are kept out of
    // backups instead, since a checkout is reproducible from the repository it came from.
    static func directory(_ name: String, backedUp: Bool = true) -> URL {
        let url = support.appendingPathComponent(name)
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

// The handful of things that are preferences rather than data: what was open last time.
// macOS has a place for these, so they do not belong in the file holding the projects.
enum Preferences {
    private static var store: UserDefaults { .standard }

    static var selectedSessionID: UUID? {
        get { uuid("selectedSessionID") }
        set { set(newValue, "selectedSessionID") }
    }

    static var selectedProjectID: UUID? {
        get { uuid("selectedProjectID") }
        set { set(newValue, "selectedProjectID") }
    }

    // What a session runs with when it has not picked for itself. A model or effort left
    // unset means the flag is never passed, so Claude Code's own configuration decides;
    // the permission mode is always ours, since the app is what asks the questions.
    static var sessionDefaults: SessionSettings {
        get {
            SessionSettings(model: text("defaultModel"),
                            effort: text("defaultEffort"),
                            permissionMode: store.string(forKey: "permissionMode") ?? "acceptEdits")
        }
        set {
            set(newValue.model, "defaultModel")
            set(newValue.effort, "defaultEffort")
            store.set(newValue.permissionMode ?? "acceptEdits", forKey: "permissionMode")
        }
    }

    private static func text(_ key: String) -> String? {
        store.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func uuid(_ key: String) -> UUID? {
        store.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private static func set(_ text: String?, _ key: String) {
        if let text, !text.isEmpty {
            store.set(text, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    private static func set(_ id: UUID?, _ key: String) {
        set(id?.uuidString, key)
    }
}
