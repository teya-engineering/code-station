import SwiftUI

// Adding a project to a workspace, from a drop in the sidebar or from the workspace's
// own page. The add happens first and the receipt says what it changed after, with a
// way to take it back: adding is cheap and fully undone, so asking before every drop
// would only slow the person down.
@MainActor
enum WorkspaceAddition {
    struct Added: Identifiable, Equatable {
        let id = UUID()
        let projectID: UUID
        // The workspace as it stood before the add, which is what an undo puts back.
        let before: ProjectWorkspace
    }

    // The receipt rises once the landing has been seen, not on top of it.
    static let receiptDelay: Duration = .milliseconds(380)

    // Adds the project and returns the workspace as it stood before, which is what an
    // undo puts back. Nil when nothing was added.
    static func add(_ projectID: UUID, to workspaceID: UUID, store: ProjectStore) -> ProjectWorkspace? {
        guard let before = store.workspace(workspaceID),
              store.addProject(projectID, toWorkspace: workspaceID) else { return nil }
        return before
    }

    static func receipt(for projectID: UUID, before: ProjectWorkspace, store: ProjectStore,
                        onUndo: @escaping () -> Void,
                        onOpen: (() -> Void)?,
                        onClose: @escaping () -> Void = {}) -> Dialog? {
        guard let project = store.project(projectID),
              let workspace = store.workspace(before.id) else { return nil }
        let members = before.projectIDs.compactMap(store.project).map {
            Dialog.Receipt.Member(name: $0.name, tint: Theme.projectTint(for: $0.name))
        }
        let sessions = store.sessions(in: workspace.id).count
        let kept: Dialog.Receipt.Row = sessions > 0
            ? .init(title: "Open sessions stay as they are",
                    detail: "\(counted(sessions, "session")) \(sessions == 1 ? "keeps" : "keep") the projects \(sessions == 1 ? "it" : "they") started with.")
            : .init(title: "Nothing else changes", detail: "No session is open in this workspace yet.")
        let worktree = workspace.worktreeProjectIDs.contains(projectID)
        let choice = Dialog.Receipt.Choice(
            label: "New sessions check it out as",
            options: [.init(title: "Worktree", hint: "A checkout of its own for each session."),
                      .init(title: "Project folder", hint: "Work directly in the folder as it is checked out.")],
            selected: project.isGitRepository && worktree ? 0 : 1,
            offReason: project.isGitRepository
                ? nil
                : "Not a git repository, so there are no worktrees to make.",
            choose: { store.setUsesWorktree($0 == 0, for: projectID, inWorkspace: workspace.id) })

        var actions: [Dialog.Action] = [
            Dialog.Action(label: "Undo", icon: "arrow.uturn.backward") {
                store.undoAddProject(projectID, toWorkspace: before)
                onUndo()
            }
        ]
        if let onOpen {
            actions.append(Dialog.Action(label: "Open workspace") {
                onClose()
                onOpen()
            })
        }
        actions.append(Dialog.Action(label: "Done", kind: .primary, handler: onClose))

        let receipt = Dialog.Receipt(
            subject: .init(name: workspace.name, kind: .workspace),
            members: members,
            added: .init(name: project.name, tint: Theme.projectTint(for: project.name)),
            message: message(project: project.name, workspace: workspace.name),
            rows: [
                .init(title: "\(project.name) is attached",
                      detail: "Every new session in this workspace can read and change it.",
                      added: true),
                kept,
                .init(title: "It is still a project of its own",
                      detail: "It keeps its place in the sidebar and its own sessions.")
            ],
            choice: choice)
        return .receipt("Project added", receipt: receipt, actions: actions, onClose: onClose)
    }

    static func message(project: String, workspace: String) -> AttributedString {
        func name(_ text: String) -> AttributedString {
            var name = AttributedString(text)
            name.inlinePresentationIntent = .stronglyEmphasized
            name.foregroundColor = .primary
            return name
        }
        return name(project) + AttributedString(" is now part of ") + name(workspace) + AttributedString(".")
    }
}
