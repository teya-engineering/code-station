import Foundation
import CodeStationCore

// The confirmation half of the removal. It builds a Dialog, so it stays in the GUI.
@MainActor
extension SessionRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ session: ChatSession, in store: ProjectStore, runner: SessionRunner,
                        workingTrees: WorkingTreeWatch, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live,
                        onSuccess: (() -> Void)? = nil) {
        dialogs.show(confirmation(for: session, in: store, workingTrees: workingTrees) {
            Task {
                switch await run([session], in: store, runner: runner, worktrees: worktrees) {
                case .success:
                    onSuccess?()
                case .failure(let failure):
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // What goes with the session, named before it goes (see `SessionRemoval.impact`),
    // shown as the impact dialog.
    static func confirmation(for session: ChatSession, in store: ProjectStore,
                             workingTrees: WorkingTreeWatch,
                             onConfirm: @escaping () -> Void) -> Dialog {
        var dialog = Dialog.impact(impact(of: session, in: store, isDirty: workingTrees.isDirty), handler: onConfirm)
        dialog.width = 420
        dialog.impact?.compact = true
        return dialog
    }
}
