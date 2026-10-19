import Foundation

// The preferences the session runner reads, next to the type they store.
extension Preferences {
    // How much memory a single turn may hold before the app stops it to keep the Mac
    // usable. Stored as whole gigabytes, with zero meaning the automatic share.
    public static func sessionMemoryLimit(in store: UserDefaults = Preferences.defaults) -> SessionMemoryLimit {
        guard store.object(forKey: "sessionMemoryLimit") != nil else {
            return SessionMemoryLimit.fallback
        }
        return SessionMemoryLimit.resolved(store.integer(forKey: "sessionMemoryLimit"))
    }

    public static func setSessionMemoryLimit(_ limit: SessionMemoryLimit,
                                      in store: UserDefaults = Preferences.defaults) {
        store.set(limit.rawValue, forKey: "sessionMemoryLimit")
    }
}
