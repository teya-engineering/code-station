import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The shortcuts screen as the app holds it: the view (`ShortcutsScreen`) and the station
// work its keys start. The app opens one with a scope (a project's or session's id, or
// nil for the Mac's own list), hands it keys while it is up, asks it again once a second
// while a command may be printing, and draws its frame over everything.
@MainActor
final class ShortcutsOverlay {
    private(set) var screen: ShortcutsScreen
    private let commands: any StationInterface
    private let work: (@escaping @MainActor () async -> Void) -> Task<Void, Never>
    private let repaint: @MainActor () -> Void
    // Asks before a removal, with what goes and what stays, as `Dialog.impact` does.
    private let confirm: @MainActor (ImpactConfirmation, @escaping @MainActor () -> Void) -> Void
    // Whether a read is on its way, so the ticker does not stack them up.
    private var reading = false

    init(scope: String?, commands: any StationInterface, theme: TranscriptTheme,
         work: @escaping (@escaping @MainActor () async -> Void) -> Task<Void, Never>,
         repaint: @escaping @MainActor () -> Void,
         confirm: @escaping @MainActor (ImpactConfirmation, @escaping @MainActor () -> Void) -> Void) {
        screen = ShortcutsScreen(scope: scope, theme: theme)
        self.commands = commands
        self.work = work
        self.repaint = repaint
        self.confirm = confirm
        reload()
    }

    var place: KeyBindings.Place { screen.isEditing ? .shortcutEditor : .shortcuts }
    // Whether keys type text, so `?` and the like are left to the editor.
    var takesTyping: Bool { screen.isEditing }

    func frame(size: TerminalSize, now: Date) -> (lines: [String], cursor: Screen.Cursor?) {
        screen.frame(size: size, now: now)
    }

    // False for a key it does not take. `close` says the screen should go.
    enum Answer { case handled, ignored, close }

    func handle(_ key: Key) -> Answer {
        switch screen.handle(key) {
        case .handled: return .handled
        case .ignored: return .ignored
        case .close: return .close
        case .run(let id):
            command { commands, scope throws(StationRefusal) in try await commands.runShortcut(id, in: scope) }
        case .stop(let id):
            command { commands, scope throws(StationRefusal) in try await commands.stopShortcut(id, in: scope) }
        case .showOutput(let id):
            command { commands, scope throws(StationRefusal) in try await commands.readShortcutOutput(id, in: scope) }
        case .save(let draft): save(draft)
        case .remove(let shortcut): askToRemove(shortcut)
        }
        return .handled
    }

    // The list again, and the open output, as the station has them now. The ticker calls
    // it once a second while the screen is up.
    func reload() {
        guard !reading else { return }
        reading = true
        let scope = screen.scope, open = screen.output?.shortcutID
        _ = work { [weak self, commands] in
            defer { self?.reading = false }
            do throws(StationRefusal) {
                let list = try await commands.listShortcuts(in: scope)
                var output: RemoteShortcutOutput?
                if let open { output = try await commands.readShortcutOutput(open, in: scope) }
                guard let self else { return }
                self.screen.show(list)
                // The output closed or moved on meanwhile is left as it is now.
                if self.screen.output?.shortcutID == open { self.screen.show(output) }
            } catch {
                self?.screen.notice = error.message
            }
            self?.repaint()
        }
    }

    // Runs, stops or reads one shortcut's output, which then shows under the list.
    private func command(_ body: @escaping @MainActor (any StationInterface, String?) async throws(StationRefusal)
                            -> RemoteShortcutOutput) {
        let scope = screen.scope
        _ = work { [weak self, commands] in
            do throws(StationRefusal) {
                let output = try await body(commands, scope)
                self?.screen.show(output)
                self?.screen.select(output.shortcutID)
            } catch {
                self?.screen.notice = error.message
            }
            self?.reload()
            self?.repaint()
        }
    }

    private func save(_ draft: RemoteShortcutDraft) {
        _ = work { [weak self, commands] in
            do throws(StationRefusal) {
                let id = try await commands.saveShortcut(draft)
                guard let self else { return }
                self.screen.closeEditor()
                self.screen.select(id)
                self.screen.notice = draft.id == nil ? "Saved \(draft.name.trimmed)." : "Saved."
            } catch {
                self?.screen.editorRefused(error.message)
            }
            self?.reload()
            self?.repaint()
        }
    }

    // As the GUI asks: the saved command goes, a run of it is stopped, the projects and
    // conversations stay, and it cannot be restored.
    private func askToRemove(_ shortcut: RemoteShortcut) {
        var rows = [ImpactConfirmation.Row("Saved command",
                                           shortcut.availableInAllProjects ? "Removed from every project."
                                           : shortcut.projectID == nil ? "Removed from this Mac."
                                           : "Removed from this project.")]
        if shortcut.run.outcome == .running {
            rows.append(ImpactConfirmation.Row("Running commands", "Stopped right away."))
        }
        rows.append(ImpactConfirmation.Row("Projects and conversations", "Kept unchanged.", kept: true))
        let subject = shortcut.projectName.map { ImpactConfirmation.Subject(name: $0) }
        let view = ImpactConfirmation("Remove \(shortcut.name)?", subject: subject, rows: rows,
                                      warning: "This shortcut cannot be restored after removal.",
                                      action: "Remove shortcut")
        confirm(view) { [weak self] in
            guard let self else { return }
            _ = self.work { [weak self, commands] in
                do throws(StationRefusal) {
                    try await commands.removeShortcut(shortcut.id)
                    if self?.screen.output?.shortcutID == shortcut.id { self?.screen.show(nil) }
                } catch {
                    self?.screen.notice = error.message
                }
                self?.reload()
                self?.repaint()
            }
        }
    }
}
