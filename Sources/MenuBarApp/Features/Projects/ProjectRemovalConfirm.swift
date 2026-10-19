import Foundation
import CodeStationCore

// The confirmation half of the removal. It builds a Dialog, so it stays in the GUI.
@MainActor
extension ProjectRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                        shortcuts: ShortcutStore, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live) {
        dialogs.show(confirmation(for: project, in: store, shortcuts: shortcuts) {
            Task {
                // The commands saved against the project go with it. Nothing can bring
                // them back by re-adding the folder - a project added again is a new one -
                // so leaving them would only mean rows filed under a name the app no
                // longer knows.
                if case .failure(let failure) = await run(
                    project, in: store, runner: runner, worktrees: worktrees,
                    removeOwned: { shortcuts.removeAll(ownedBy: $0) }) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // A task's folder was created by the app inside its own support directory, so deleting
    // the task takes the folder with it. A folder the user chose always stays. What the
    // rows say is the core's, which a terminal asks with too.
    static func confirmation(for project: Project, in store: ProjectStore,
                             shortcuts: ShortcutStore? = nil,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let saved = shortcuts?.shortcuts.count { $0.projectID == project.id } ?? 0
        return .impact(impact(of: project, in: store, savedShortcuts: saved), handler: onConfirm)
    }
}

extension Dialog {
    // The impact dialog for what the core says a removal takes and leaves.
    static func impact(_ impact: RemoteImpact, handler: @escaping () -> Void) -> Dialog {
        .impact(impact.title, message: impact.message,
                subject: impact.subject.map { Impact.Subject(name: $0.name, kind: Impact.Subject.Kind($0.kind)) },
                rows: impact.rows.map { Impact.Row(title: $0.title, detail: $0.detail, kept: $0.kept) },
                warning: impact.warning, action: impact.action, handler: handler)
    }
}

extension Dialog.Impact.Subject.Kind {
    init(_ kind: RemoteContainer.Kind) {
        switch kind {
        case .project: self = .project
        case .task: self = .task
        case .workspace: self = .workspace
        }
    }
}
