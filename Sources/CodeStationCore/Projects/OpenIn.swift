import Foundation

// Where "Open in" sends a session's folder: the code editors on this Mac, Finder, and the
// chosen terminal. Which apps are installed is the host's to find out; which ones count,
// in what order, and which one the button points at are decided here, so every host
// offers the same choice.
public enum OpenIn {
    public static let finderID = "com.apple.finder"

    // Editors that open a folder as a project. Only the ones installed are offered.
    public static let editorIDs = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
    ]

    // An app that has been removed since it was picked falls back to Finder, which every
    // Mac has, so the button never points at nothing.
    public static func chosen(from apps: [OpenInApp], saved: String?) -> OpenInApp? {
        apps.first { $0.bundleID == saved }
            ?? apps.first { $0.bundleID == finderID }
            ?? apps.first
    }

    // The app the button points at, among those the host found.
    public static func current(from apps: [OpenInApp]) -> OpenInApp? {
        chosen(from: apps, saved: Preferences.openInBundleID)
    }

    // Remembered, so the main half of the button does the same thing every time until
    // someone picks another.
    public static func choose(_ app: OpenInApp) {
        Preferences.openInBundleID = app.bundleID
    }

    // Editors first, then Finder, then the terminal. An app that turns up twice, such as a
    // terminal that is also listed as an editor, is only offered once.
    public static func ordered(editors: [OpenInApp], finder: OpenInApp?,
                               terminal: OpenInApp?) -> [OpenInApp] {
        var seen = Set<String>()
        return (editors + [finder, terminal].compactMap(\.self))
            .filter { seen.insert($0.bundleID).inserted }
    }
}
