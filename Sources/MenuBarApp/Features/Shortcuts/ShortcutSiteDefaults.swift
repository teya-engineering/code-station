import AppKit
import CodeStationCore

// The shortcut store lives in the core, so every station host can run shortcuts for its
// clients. What it knows of the GUI's site configuration and of SF Symbols is joined to it
// here.
extension ShortcutStore {
    convenience init(storageURL: URL? = nil, siteDefaults: SiteDefaults = .current) {
        ShortcutIcon.installSymbolCheck()
        self.init(storageURL: storageURL, startingShortcuts: siteDefaults.startingShortcuts)
    }

    func applySiteDefaults(_ defaults: SiteDefaults) {
        applySiteShortcuts(defaults.startingShortcuts)
    }

    func resetSiteShortcuts(to defaults: SiteDefaults) {
        resetSiteShortcuts(to: defaults.startingShortcuts)
    }

    func load(siteDefaults: SiteDefaults = .current) {
        load(startingShortcuts: siteDefaults.startingShortcuts)
    }

    var siteConfigurationShortcuts: [SiteDefaults.ShortcutEntry] {
        siteShortcuts.map {
            SiteDefaults.ShortcutEntry(name: $0.name, command: $0.text, icon: $0.icon)
        }
    }
}

extension ShortcutIcon {
    // Shortcuts read anywhere in the app keep only a symbol AppKit can draw. Installed
    // once, before the first shortcut is built.
    private static let symbolCheck: Void = ShortcutSymbols.install { symbol in
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }

    static func installSymbolCheck() {
        _ = symbolCheck
    }
}
