import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the MCP config manager.
struct AppSidebar: View {
    let onConfigureServers: () -> Void
    let onOpenDocker: () -> Void
    let onOpenSettings: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs

    // A project is expanded by default while it is the selected one; anything the user
    // clicks on the disclosure arrow is remembered here and wins over that default.
    @State private var expansion: [UUID: Bool] = [:]
    @State private var renamingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
        }
        .frame(width: 292)
        .background(Theme.sidebar)
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Projects").font(.serif(24, .semibold))
            Text("\(busyCount) of \(store.sessions.count) running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var busyCount: Int {
        store.sessions.filter { runner.state($0.id).isBusy }.count
    }

    // MARK: - Projects

    @ViewBuilder private var projectList: some View {
        if store.projects.isEmpty {
            Text("No projects yet. Add a folder and Claude Code will run right inside it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.projects) { project in
                        projectSection(project)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private func projectSection(_ project: Project) -> some View {
        let expanded = isExpanded(project)
        let sessions = store.sessions(for: project.id)

        ProjectHeaderRow(
            project: project,
            isExpanded: expanded,
            isMissing: store.isMissing(project),
            hasBusySession: sessions.contains { runner.state($0.id).isBusy },
            isRenaming: renamingID == project.id,
            onToggle: { expansion[project.id] = !expanded },
            onNewSession: { requestNewSession(in: project) },
            onRename: { name in
                store.renameProject(project.id, to: name)
                renamingID = nil
            },
            onCancelRename: { renamingID = nil }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedProjectID = project.id
            expansion[project.id] = !expanded
        }
        .appContextMenu {
            [.item("Rename…") { renamingID = project.id },
             .item("New session") { requestNewSession(in: project) },
             .separator,
             .item("Reveal in Finder") {
                 NSWorkspace.shared.activateFileViewerSelecting([project.url])
             },
             .item("Open in Terminal") { openInTerminal(project) },
             .separator,
             .item("Remove project", kind: .destructive) { confirmRemoveProject(project) }]
        }

        if expanded {
            ForEach(sessions) { session in
                SessionRow(session: session,
                           selected: isSelected(session),
                           busy: runner.state(session.id).isBusy,
                           activity: activityLine(session, project: project),
                           additions: additions(session, project: project),
                           onDelete: { confirmRemoveSession(session) })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectedProjectID = project.id
                        store.selection = .session(session.id)
                    }
                    .appContextMenu {
                        [.item("Delete session", kind: .destructive) {
                            confirmRemoveSession(session)
                        }]
                    }
            }
            NewSessionRow { requestNewSession(in: project) }
        }
    }

    private func isExpanded(_ project: Project) -> Bool {
        expansion[project.id] ?? (project.id == store.selectedProject?.id)
    }

    // MARK: - Creating and removing sessions

    // A git repository gets the folder-or-worktree choice; a plain folder has no
    // worktrees to offer, so the session is just created.
    private func requestNewSession(in project: Project) {
        guard FileManager.default.fileExists(atPath: project.path + "/.git") else {
            store.newSession(in: project.id)
            return
        }
        dialogs.show(Dialog(
            title: "New session in \(project.name)",
            message: "A worktree is an isolated checkout on its own branch, so several sessions of this project can run at once. Working in the folder itself edits your working tree directly, one session at a time.",
            actions: [
                .init(label: "Use a git worktree", kind: .primary) {
                    createWorktreeSession(in: project)
                },
                .init(label: "Work in the project folder") {
                    store.newSession(in: project.id)
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func confirmRemoveSession(_ session: ChatSession) {
        guard let worktree = session.worktreePath else {
            store.removeSession(session.id)
            return
        }
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: "Uncommitted changes in its worktree at \(worktree.abbreviatedPath) are lost. The branch is kept if it has unmerged commits.",
            actions: [
                .init(label: "Delete session and worktree", kind: .destructive) {
                    removeSession(session)
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func confirmRemoveProject(_ project: Project) {
        let count = store.sessions(for: project.id).count
        dialogs.show(Dialog(
            title: "Remove \(project.name)?",
            message: "This drops its \(count) session\(count == 1 ? "" : "s") from the app and removes any worktrees they used. The folder itself stays on disk.",
            actions: [
                .init(label: "Remove project", kind: .destructive) { removeProject(project) },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // The session id is chosen up front so the worktree folder and branch can carry
    // it before the session exists.
    private func createWorktreeSession(in project: Project) {
        let sessionID = UUID()
        Task {
            do {
                let created = try await GitWorktree.add(projectPath: project.path,
                                                        projectName: project.name,
                                                        sessionID: sessionID)
                store.newSession(in: project.id, id: sessionID,
                                 worktreePath: created.path, worktreeBranch: created.branch)
            } catch {
                dialogs.show(Dialog(
                    title: "Could not create a worktree",
                    message: error.localizedDescription,
                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func removeSession(_ session: ChatSession) {
        let project = store.project(session.projectID)
        store.removeSession(session.id)
        guard let worktree = session.worktreePath, let project else { return }
        Task {
            await GitWorktree.remove(worktreePath: worktree,
                                     projectPath: project.path,
                                     branch: session.worktreeBranch)
        }
    }

    private func removeProject(_ project: Project) {
        let worktreeSessions = store.sessions(for: project.id).filter { $0.worktreePath != nil }
        store.removeProject(project.id)
        guard !worktreeSessions.isEmpty else { return }
        Task {
            for session in worktreeSessions {
                await GitWorktree.remove(worktreePath: session.worktreePath ?? "",
                                         projectPath: project.path,
                                         branch: session.worktreeBranch)
            }
        }
    }

    // "Bash · swift build": the tool call that is in flight right now, if any.
    private func activityLine(_ session: ChatSession, project: Project) -> String? {
        guard let message = session.messages.last, message.role == .assistant,
              let tool = message.tools.last(where: { $0.isRunning }) else { return nil }
        let root = session.worktreePath ?? project.path
        let presentation = ToolPresentationCache.presentation(for: tool, projectPath: root)
        guard !presentation.argument.isEmpty else { return presentation.verb }
        return "\(presentation.verb) · \(presentation.argument)"
    }

    // Lines this session's edits have added, summed over the whole conversation. A
    // rough measure, but enough to tell a session that wrote code from one that only
    // answered a question.
    private func additions(_ session: ChatSession, project: Project) -> Int {
        let root = session.worktreePath ?? project.path
        return session.messages.flatMap(\.tools).reduce(0) { total, tool in
            guard !tool.isError, !tool.isRunning else { return total }
            let presentation = ToolPresentationCache.presentation(for: tool, projectPath: root)
            return total + (presentation.added ?? 0)
        }
    }

    private func isSelected(_ session: ChatSession) -> Bool {
        if case .session(let id) = store.selection { return id == session.id }
        return false
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: addProject) {
                Text("+ Add project")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .padding(16)

            Divider().overlay(Theme.hairline)

            VStack(spacing: 2) {
                BottomRow(icon: "server.rack",
                          title: "MCP Servers",
                          trailing: "slider.horizontal.3",
                          action: onConfigureServers)
                BottomRow(icon: "shippingbox",
                          title: "Docker",
                          action: onOpenDocker)
                BottomRow(icon: "gearshape",
                          title: "Settings",
                          action: onOpenSettings)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, runner.available ? 12 : 6)

            if !runner.available {
                Text("Claude Code was not found on PATH.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Actions

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder Claude Code should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A folder that is already a project comes back as nil, and the store has
        // pointed itself at the existing one, so there is nothing to report.
        let added = store.addProject(at: url)
        if let id = added?.id ?? store.selectedProjectID { expansion[id] = true }
    }

    // Opening a folder on its own would just reveal it in Finder, so name the app.
    private func openInTerminal(_ project: Project) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([project.url],
                                withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Rows

// The pinned rows under the project list: the places you go to set something up rather
// than to work.
private struct BottomRow: View {
    let icon: String
    let title: String
    var trailing: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.black.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ProjectHeaderRow: View {
    let project: Project
    let isExpanded: Bool
    let isMissing: Bool
    let hasBusySession: Bool
    let isRenaming: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($focused)
                        .onSubmit { onRename(draft) }
                        .onExitCommand(perform: onCancelRename)
                } else {
                    HStack(spacing: 5) {
                        if isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(isMissing ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Collapsed projects would otherwise give no sign that work is running.
            if hasBusySession, !isExpanded {
                Circle().fill(Theme.dotOn).frame(width: 7, height: 7)
            }
            if hovering, !isRenaming {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.black.opacity(0.03) : .clear))
        .onHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool
    let activity: String?
    let additions: Int
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Circle()
                    .fill(busy ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 7, height: 7)
                if session.worktreePath != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Runs in its own git worktree")
                }
                Text(session.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // The counter steps aside on hover: the row is narrow, and the delete
                // button is what the pointer is there for.
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete session")
                } else if !busy, additions > 0 {
                    Text("+\(additions)")
                        .font(.mono(11, .medium))
                        .foregroundStyle(Theme.addition)
                }
            }

            if busy {
                VStack(alignment: .leading, spacing: 4) {
                    ActivityBar()
                    if let activity {
                        Text(activity)
                            .font(.mono(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.black.opacity(0.06) : hovering ? Color.black.opacity(0.03) : .clear))
        .padding(.leading, 18)
        .onHover { hovering = $0 }
    }
}

// A slow back-and-forth slide: there is no way to know how far along a turn is, so
// the bar only says "still working".
private struct ActivityBar: View {
    @State private var sliding = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.dotOff.opacity(0.35))
                Capsule()
                    .fill(Theme.dotOn)
                    .frame(width: geometry.size.width * 0.4)
                    .offset(x: sliding ? geometry.size.width * 0.6 : 0)
            }
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                sliding = true
            }
        }
    }
}

private struct NewSessionRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("New session").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.black.opacity(0.04) : .clear))
            .padding(.leading, 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
