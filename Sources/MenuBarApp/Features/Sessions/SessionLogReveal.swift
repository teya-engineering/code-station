import AppKit
import CodeStationCore
import Foundation

extension SessionLog {
    // Where a stuck turn is usually explained, so it is worth having by hand rather than
    // hunting for the file.
    static func revealInFinder() {
        // Nothing has been logged yet on a fresh install, and Finder cannot reveal a file
        // that is not there.
        if !FileManager.default.fileExists(atPath: file.path) { note("log opened") }
        flush()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
