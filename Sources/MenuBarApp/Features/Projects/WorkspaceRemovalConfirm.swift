import Foundation
import CodeStationCore

// The confirmation half of the removal. It builds a Dialog, so it stays in the GUI.
@MainActor
extension WorkspaceRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ workspace: ProjectWorkspace, in store: ProjectStore,
                        runner: SessionRunner, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live) {
        dialogs.show(confirmation(for: workspace, in: store) {
            Task {
                if case .failure(let failure) = await run(workspace, in: store, runner: runner,
                                                          worktrees: worktrees) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // What the rows say is the core's, which a terminal asks with too.
    static func confirmation(for workspace: ProjectWorkspace, in store: ProjectStore,
                             onConfirm: @escaping () -> Void) -> Dialog {
        .impact(impact(of: workspace, in: store), handler: onConfirm)
    }
}
