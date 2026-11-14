import Observation
import SwiftUI

// The rows picked in the sidebar for one action on all of them. Holding a row down opens
// the selection with that row in it. While it is open a click ticks a row instead of
// opening it, and it closes once nothing is left ticked.
@MainActor
@Observable
final class SidebarMultiSelection {
    private(set) var ids: Set<UUID> = []

    // The press that opened the selection still ends in a click on the row under it.
    // That click has already been answered by the hold, so it must not untick the row.
    @ObservationIgnored private var holding = false

    var isActive: Bool { !ids.isEmpty }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    func hold(_ id: UUID) {
        ids.insert(id)
        holding = true
        PressAndHold.afterRelease { [weak self] in self?.holding = false }
    }

    func click(_ id: UUID) {
        guard !holding else { return }
        if ids.remove(id) == nil { ids.insert(id) }
    }

    func add(_ id: UUID) { ids.insert(id) }

    func clear() { ids.removeAll() }

    // Drops rows that have left the sidebar, so a deleted row cannot hold the selection open.
    func keep(where exists: (UUID) -> Bool) {
        let kept = ids.filter(exists)
        if kept != ids { ids = kept }
    }
}

// What a sidebar selection stands for, and the actions it offers.
@MainActor
enum SidebarBulkAction {
    struct Targets {
        var projects: [Project] = []
        var workspaces: [ProjectWorkspace] = []
        var sessions: [ChatSession] = []

        var isEmpty: Bool { projects.isEmpty && workspaces.isEmpty && sessions.isEmpty }
    }

    // In sidebar order, so a dialog lists things the way the user sees them.
    static func targets(_ ids: Set<UUID>, in store: ProjectStore) -> Targets {
        Targets(projects: store.projects.filter { ids.contains($0.id) },
                workspaces: store.workspaces.filter { ids.contains($0.id) },
                sessions: store.sidebarSessions.filter { ids.contains($0.id) })
    }

    // Cleanup is snoozed per project, so a session or workspace snoozes the project whose
    // deadline holds its sessions back. For a workspace that is its lead project, plus the
    // home project of each session in it.
    static func snoozeProjects(_ targets: Targets, in store: ProjectStore) -> [Project] {
        var ids = Set(targets.projects.map(\.id))
        ids.formUnion(targets.sessions.map(\.projectID))
        for workspace in targets.workspaces {
            ids.insert(workspace.leadProjectID)
            ids.formUnion(store.sessions(in: workspace.id).map(\.projectID))
        }
        return store.projects.filter { ids.contains($0.id) }
    }

    static func snoozeMenu(_ targets: Targets, in store: ProjectStore) -> [MenuEntry] {
        let projects = snoozeProjects(targets, in: store)
        guard !projects.isEmpty else { return [] }
        let names = projects.map(\.name).formatted(.list(type: .and))
        var entries: [MenuEntry] = [
            .item("Snooze cleanup 1 day", icon: "clock", subtitle: names) {
                for project in projects { store.snoozeCleanup(forProject: project.id) }
            }]
        let snoozed = projects.filter { ProjectSnooze.isActive($0.snoozedUntil) }
        if !snoozed.isEmpty {
            entries.append(.item("Wake now", icon: "clock.badge.xmark",
                                 subtitle: snoozed.map(\.name).formatted(.list(type: .and))) {
                for project in snoozed { store.wakeCleanup(forProject: project.id) }
            })
        }
        return entries
    }

    // Every session that goes: the ones picked, and the ones inside a picked project or
    // workspace. A workspace session also goes with any project it has a checkout in.
    static func sessionsRemoved(by targets: Targets, in store: ProjectStore) -> [ChatSession] {
        var seen: Set<UUID> = []
        let all = targets.projects.flatMap { ProjectRemoval.sessions(using: $0.id, in: store) }
            + targets.workspaces.flatMap { store.sessions(in: $0.id) }
            + targets.sessions
        return all.filter { seen.insert($0.id).inserted }
    }

    static func confirmation(for targets: Targets, in store: ProjectStore,
                             shortcuts: ShortcutStore, workingTrees: WorkingTreeWatch,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let sessions = sessionsRemoved(by: targets, in: store)
        let worktrees = sessions.flatMap { store.checkoutProjects(for: $0).compactMap(\.worktreePath) }
        let dirty = worktrees.count(where: workingTrees.isDirty)
        let designs = sessions.count { store.hasDesignArtifacts(for: $0) }
        let tasks = targets.projects.filter { $0.kind == .adHoc }
        let projects = targets.projects.filter { $0.kind != .adHoc }
        let projectIDs = Set(targets.projects.map(\.id))
        let saved = shortcuts.shortcuts.count { $0.projectID.map(projectIDs.contains) ?? false }

        var rows: [Dialog.Impact.Row] = []
        if !sessions.isEmpty {
            rows.append(.init(
                title: worktrees.isEmpty
                    ? counted(sessions.count, "session")
                    : "\(counted(sessions.count, "session")) and \(counted(worktrees.count, "worktree"))",
                detail: "Conversation history is removed from Code Station."
                    + (worktrees.isEmpty ? ""
                       : dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "worktree has" : "worktrees have") uncommitted changes that will be lost."
                       : " Worktrees are removed from disk. Branches are kept if they have unmerged commits.")))
        }
        if !projects.isEmpty {
            rows.append(.init(title: counted(projects.count, "project"),
                              detail: "Removed from Code Station and every workspace they belong to."))
        }
        if !targets.workspaces.isEmpty {
            rows.append(.init(title: counted(targets.workspaces.count, "workspace"),
                              detail: "Removed from Code Station. The projects they group stay."))
        }
        if !tasks.isEmpty {
            rows.append(.init(title: counted(tasks.count, "task"),
                              detail: "Deleted from disk, with any files their runs left in their folders."))
        }
        if saved > 0 {
            rows.append(.init(title: counted(saved, "saved shortcut"),
                              detail: "Commands saved for these projects are permanently removed."))
        }
        if designs > 0 {
            rows.append(.init(title: "Generated Design files",
                              detail: "Permanently removed from \(counted(designs, "session"))."))
        }
        if !projects.isEmpty || !targets.workspaces.isEmpty
            || targets.sessions.contains(where: { store.project($0.projectID)?.kind != .adHoc }) {
            rows.append(.init(title: "Project folders stay",
                              detail: "Folders you added are not touched. Only worktrees are removed.",
                              kept: true))
        }

        let warning: String? = if dirty > 0 {
            "Uncommitted changes and conversation history cannot be restored."
        } else if !tasks.isEmpty {
            "Task folders and conversation history cannot be restored."
        } else if !sessions.isEmpty {
            "Conversation history cannot be restored."
        } else {
            nil
        }
        return .impact("Delete \(summary(of: targets))?",
                       message: "Everything selected will leave Code Station.",
                       subject: subject(of: targets, in: store),
                       rows: rows, warning: warning, action: "Delete", handler: onConfirm)
    }

    // "2 sessions, 1 project and 1 workspace"
    static func summary(of targets: Targets) -> String {
        let tasks = targets.projects.count { $0.kind == .adHoc }
        let projects = targets.projects.count - tasks
        var parts: [String] = []
        if !targets.sessions.isEmpty { parts.append(counted(targets.sessions.count, "session")) }
        if projects > 0 { parts.append(counted(projects, "project")) }
        if !targets.workspaces.isEmpty { parts.append(counted(targets.workspaces.count, "workspace")) }
        if tasks > 0 { parts.append(counted(tasks, "task")) }
        return parts.formatted(.list(type: .and))
    }

    // Sessions picked from one project or workspace show its tile at the top, the way a
    // single deletion does.
    private static func subject(of targets: Targets, in store: ProjectStore) -> Dialog.Impact.Subject? {
        guard targets.projects.isEmpty, targets.workspaces.isEmpty,
              let first = targets.sessions.first else { return nil }
        let container = first.workspaceID ?? first.projectID
        guard targets.sessions.allSatisfy({ ($0.workspaceID ?? $0.projectID) == container })
        else { return nil }
        if let workspace = store.workspace(container) {
            return .init(name: workspace.name, kind: .workspace)
        }
        guard let project = store.project(container) else { return nil }
        return .init(name: project.name, kind: project.kind == .adHoc ? .task : .project)
    }

    // Containers first, so their sessions go with them, then whatever picked sessions are
    // left. One refusal does not stop the rest, and every reason is reported at the end.
    static func run(_ targets: Targets, in store: ProjectStore, runner: SessionRunner,
                    shortcuts: ShortcutStore, worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        var failures: [SessionLifecycle.Failure] = []
        for workspace in targets.workspaces {
            if case .failure(let failure) = await WorkspaceRemoval.run(
                workspace, in: store, runner: runner, worktrees: worktrees) {
                failures.append(failure)
            }
        }
        for project in targets.projects {
            if case .failure(let failure) = await ProjectRemoval.run(
                project, in: store, runner: runner, shortcuts: shortcuts, worktrees: worktrees) {
                failures.append(failure)
            }
        }
        let left = targets.sessions.filter { store.session($0.id) != nil }
        if case .failure(let failure) = await SessionRemoval.run(
            left, in: store, runner: runner, worktrees: worktrees) {
            failures.append(failure)
        }
        guard failures.isEmpty else {
            return .failure(SessionLifecycle.Failure(
                title: failures.count == 1 ? failures[0].title : "Could not delete everything",
                message: failures.map(\.message).joined(separator: "\n")))
        }
        return .success(())
    }
}

// Takes the place of the sort and grouping bar while rows are being picked. Sorting
// would move the rows out from under the pointer, and this is where the user learns how
// to act on what they picked and how to stop.
struct SidebarSelectionBar: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Text("\(count) selected")
                .font(Typography.caption.weight(.semibold))
                .contentTransition(.numericText(value: Double(count)))
                .motion(Motion.pop, value: count)
            Text("Right-click for actions")
                .font(Font.system(size: Typography.Size.micro))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onDone) {
                Text("Done")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift()
            .accessibilityHint("Stops selecting. Escape does the same.")
        }
        .frame(height: 43)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .padding(.horizontal, Space.lg)
    }
}
