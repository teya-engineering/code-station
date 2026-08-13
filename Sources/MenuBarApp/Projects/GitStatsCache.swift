import Foundation
import SwiftUI

// The last git snapshot taken of each worktree, shared by every screen that shows one.
//
// Snapshots live here rather than in the views that fetch them so a screen can open
// with the numbers it showed last time and let a background refresh correct them,
// instead of opening blank while git is asked again from scratch.
@MainActor
@Observable
final class GitStatsCache {
    private var snapshots: [String: GitSnapshot] = [:]
    // When each answer landed. Not observed: freshness decides whether to ask git again,
    // and nothing on screen is drawn from it.
    @ObservationIgnored private var takenAt: [String: ContinuousClock.Instant] = [:]

    func snapshot(at path: String) -> GitSnapshot? {
        snapshots[Self.normalized(path)]
    }

    // Git runs on a serial queue, so asking again for a tree that was just inspected
    // does not only repeat the work - it puts it in front of the tree being opened now.
    func isFresh(at path: String, within age: Duration) -> Bool {
        guard let taken = takenAt[Self.normalized(path)] else { return false }
        return ContinuousClock.now - taken < age
    }

    // Only a successful inspection is worth keeping. A failed one carries no numbers,
    // and it also means the tree can no longer be trusted - the folder or repository
    // may be gone - so whatever was remembered for it is dropped rather than shown stale.
    func store(_ snapshot: GitSnapshot, at path: String) {
        let key = Self.normalized(path)
        if snapshot.state == .ready {
            snapshots[key] = snapshot
            takenAt[key] = ContinuousClock.now
        } else {
            snapshots.removeValue(forKey: key)
            takenAt.removeValue(forKey: key)
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
