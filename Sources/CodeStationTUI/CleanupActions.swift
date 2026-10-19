import CodeStationCore
import Foundation
import TerminalKit

// What the TUI does from the cleanup strips at the sidebar's foot and the warning strip
// under the top bar, as the GUI does from its own: the old-sessions strip opens the review
// (`OldSessionsScreen`), the orphaned-worktrees strip asks with every worktree named and
// prunes them, and R over a session with a lost worktree asks with where its commits come
// from and rebuilds it. Every question is read from the station first.
extension TUIApp {

    // MARK: - Orphaned worktrees

    func askToPruneOrphans() {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let orphans = try await commands.readOrphanedWorktrees()
                guard !orphans.isEmpty else {
                    self?.sidebar.notice = "No orphaned worktrees are left."
                    self?.paint()
                    return
                }
                self?.confirmation = (ImpactConfirmation(RemoteOrphanedWorktree.pruneImpact(orphans)),
                                      then: { [weak self] in self?.prune(orphans.map(\.path)) })
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func prune(_ paths: [String]) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.pruneOrphanedWorktrees(paths: paths)
            } catch {
                self?.sidebar.notice = "Could not prune some worktrees: " + error.message
            }
            self?.paint()
        }
    }

    // MARK: - Old sessions

    func openOldSessions() {
        oldSessions = OldSessionsScreen()
        readOldSessions()
    }

    private func readOldSessions() {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let review = try await commands.readOldSessions()
                self?.oldSessions?.show(review)
            } catch {
                self?.oldSessions?.notice = error.message
            }
            self?.paint()
        }
    }

    func handleInOldSessions(_ key: Key) -> Bool {
        guard var screen = oldSessions else { return false }
        let outcome = screen.handle(key, rows: terminalRows)
        oldSessions = screen
        switch outcome {
        case .ignored: return false
        case .handled: break
        case .close: oldSessions = nil
        case .reread: readOldSessions()
        case .snooze(let projectID): changeCleanup(projectID, .snoozeCleanup)
        case .wake(let projectID): changeCleanup(projectID, .wakeCleanup)
        case .delete:
            // The review is the question for sessions that cost nothing but history; saved
            // work is asked about twice, as the GUI does.
            let chosen = screen.chosen
            if let impact = RemoteOldSessions.deletionImpact(of: chosen) {
                confirmation = (ImpactConfirmation(impact), then: { [weak self] in self?.deleteOldSessions(chosen) })
            } else {
                deleteOldSessions(chosen)
            }
        }
        return true
    }

    private func changeCleanup(_ projectID: String, _ change: ProjectChange) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.changeProject(projectID, change)
            } catch {
                self?.oldSessions?.notice = error.message
            }
            self?.readOldSessions()
        }
    }

    // Deletes the chosen sessions and closes the review, as the GUI's sheet closes once
    // they are gone. A refusal stays in the review, read again.
    private func deleteOldSessions(_ chosen: [RemoteOldSessions.Session]) {
        oldSessions?.isDeleting = true
        oldSessions?.notice = "Deleting \(counted(chosen.count, "session"))…"
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.deleteOldSessions(chosen.map(\.id))
                self?.oldSessions = nil
            } catch {
                self?.oldSessions?.isDeleting = false
                self?.readOldSessions()
                self?.oldSessions?.notice = error.message
            }
            self?.paint()
        }
    }

    // MARK: - Rebuild

    // R over a session whose warning offers a rebuild.
    func askToRebuild(_ sessionID: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let offer = try await commands.readRebuild(sessionID)
                var view = ImpactConfirmation(offer)
                view.isDestructive = false
                self?.confirmation = (view, then: { [weak self] in self?.rebuild(sessionID) })
            } catch {
                self?.transcript?.notice = error.message
            }
            self?.paint()
        }
    }

    private func rebuild(_ sessionID: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.rebuild(sessionID)
                self?.transcript?.notice = "Rebuilt."
            } catch {
                self?.transcript?.notice = error.message
            }
            // The header's warning is read again with the folder back.
            await commands.resync(sessionID)
            self?.paint()
        }
    }
}
