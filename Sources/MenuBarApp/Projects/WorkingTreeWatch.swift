import Foundation
import SwiftUI

// Which folders hold work that git does not have yet. Sessions edit real files, either
// in the project folder or in a worktree of their own, and deleting a session takes its
// worktree with it, so the sidebar has to be able to say "there is something here to
// lose" without the session being opened.
//
// The answers are kept here rather than read where they are drawn: a row redraws far too
// often to run git, and git is far too slow to run on the main thread.
@MainActor
@Observable
final class WorkingTreeWatch {
    // How often the folders on screen are looked at again. Long enough to be invisible on
    // a big repository, short enough that committing in a terminal clears the mark while
    // you are still looking at the window.
    static let interval: Duration = .seconds(10)

    private var dirty: [String: Bool] = [:]
    // A folder already being looked at is skipped rather than queued, so a slow repository
    // cannot pile up runs behind itself. Not observed: nothing drawn depends on it.
    @ObservationIgnored private var running: Set<String> = []

    // A folder nobody has asked about reads as clean, which is what an unanswered
    // question has to look like: the mark appears when there is an answer saying so.
    func isDirty(_ path: String) -> Bool { dirty[path] ?? false }

    // The caller says which folders matter, so nothing runs git for a project whose
    // sessions are not even on screen.
    func refresh(_ paths: some Collection<String>) {
        for path in paths where !running.contains(path) {
            running.insert(path)
            Task {
                let result = await GitInspector.isDirty(at: path)
                running.remove(path)
                dirty[path] = result
            }
        }
    }
}
