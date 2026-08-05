import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the MCP config manager.
struct AppSidebar: View {
    let onConfigureServers: () -> Void
    let onOpenDocker: () -> Void
    let onOpenSettings: () -> Void
    let onOpenPostman: () -> Void

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let logo = AppArt.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                        // The art carries its own margin, so it is pulled back to sit on
                        // the same left edge as the text below it.
                        .padding(.leading, -6)
                }
                Text("Teya Conductor")
                    .font(.serif(18, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if busyCount > 0 {
                    StatusPill(text: "\(busyCount) RUNNING", running: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(Theme.hairline)
        }
    }

    private var busyCount: Int {
        store.sessions.filter { runner.state($0.id).isBusy }.count
    }

    // MARK: - Projects

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailLabel(text: "Projects · \(store.projects.count)")
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

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
                    // Keyed on the whole set so the reveal plays wherever the expansion
                    // came from, not just a click on the project row.
                    .animation(.easeOut(duration: 0.22), value: expandedIDs)
                }
            }
        }
    }

    @ViewBuilder private func projectSection(_ project: Project) -> some View {
        let expanded = isExpanded(project)
        let sessions = store.sessions(for: project.id)
        let running = sessions.filter { runner.state($0.id).isBusy }.count

        ProjectHeaderRow(
            project: project,
            isSelected: expanded,
            isMissing: store.isMissing(project),
            sessionCount: sessions.count,
            runningCount: running,
            finishedCount: store.finishedCount(in: project.id),
            lastActivity: sessions.map(\.lastActivity).max(),
            isRenaming: renamingID == project.id,
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sessions) { session in
                    SessionRow(session: session,
                               selected: isSelected(session),
                               busy: runner.state(session.id).isBusy,
                               finished: store.hasFinished(session.id),
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
            .padding(.top, 6)
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    private func isExpanded(_ project: Project) -> Bool {
        expansion[project.id] ?? (project.id == store.selectedProject?.id)
    }

    private var expandedIDs: Set<UUID> {
        Set(store.projects.filter(isExpanded).map(\.id))
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
        let worktree = session.worktreePath
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: worktree.map {
                "Uncommitted changes in its worktree at \($0.abbreviatedPath) are lost. The branch is kept if it has unmerged commits."
            } ?? "Its conversation history is removed from the app.",
            actions: [
                .init(label: worktree == nil ? "Delete session" : "Delete session and worktree",
                      kind: .destructive) {
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
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Two rows of two rather than one strip of four: at the sidebar's width a
            // four-across row leaves each label too narrow to read at full size.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    BottomRow(title: "MCP", action: onConfigureServers)
                    BottomRow(title: "Docker", action: onOpenDocker)
                }
                HStack(spacing: 8) {
                    BottomRow(title: "Settings", action: onOpenSettings)
                    BottomRow(title: "Postman", action: onOpenPostman)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, runner.available ? 16 : 6)

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

// The pinned buttons under the project list: the places you go to set something up
// rather than to work. They sit side by side, so the label carries the whole button and
// is uppercased to keep the three reading as one strip.
private struct BottomRow: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.field : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ProjectHeaderRow: View {
    let project: Project
    let isSelected: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let lastActivity: Date?
    let isRenaming: Bool
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            MonogramTile(name: project.name, badge: runningCount)

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
                        if finishedCount > 0 {
                            FinishedDot()
                                .help(finishedCount == 1
                                      ? "A session here finished while you were away"
                                      : "\(finishedCount) sessions here finished while you were away")
                        }
                    }
                }
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(isMissing ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if hovering, !isRenaming {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New session")
            } else if let lastActivity {
                Text(RelativeTime.short(lastActivity))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isSelected ? Color.black.opacity(0.05) : hovering ? Color.black.opacity(0.03) : .clear))
        .onHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }

    // The session count is what the sidebar is for; the path is the only thing that
    // tells two projects of the same name apart.
    private var meta: String {
        let sessions = "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
        return "\(sessions) · \(project.collapsedPath)"
    }
}

// The project's initial, tinted from its name, with the number of sessions running in
// it hanging off the corner.
private struct MonogramTile: View {
    let name: String
    let badge: Int

    var body: some View {
        let tint = Theme.monogram(for: name)
        RoundedRectangle(cornerRadius: 9)
            .fill(tint.opacity(0.14))
            .frame(width: 34, height: 34)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.mono(13, .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.dotOn))
                        .overlay(Circle().stroke(Theme.sidebar, lineWidth: 1.5))
                        .offset(x: 5, y: -5)
                }
            }
    }
}

// A turn ended in a session that was not on screen. It stays until that session is
// opened, which is the only thing that counts as having read it.
private struct FinishedDot: View {
    var body: some View {
        Circle()
            .fill(Theme.attention)
            .frame(width: 7, height: 7)
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool
    let finished: Bool
    let activity: String?
    let additions: Int
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if session.worktreePath != nil {
                    StatusPill(text: "WT", running: false)
                        .help("Runs in its own git worktree")
                }
                if finished {
                    FinishedDot()
                        .help("This session finished while you were away")
                }
                Text(session.title)
                    .font(.system(size: 12, weight: selected || finished ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // The state pill steps aside on hover: the row is narrow, and the
                // delete button is what the pointer is there for.
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete session")
                } else if busy {
                    StatusPill(text: "Running", running: true)
                } else if additions > 0 {
                    Text("+\(additions)")
                        .font(.mono(11, .medium))
                        .foregroundStyle(Theme.addition)
                } else {
                    StatusPill(text: "Idle", running: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(rowFill))
            .animation(.easeOut(duration: 0.25), value: [busy, finished])

            ActivityLine(activity: busy ? activity : nil)
        }
        .padding(.leading, 18)
        .onHover { hovering = $0 }
    }

    // What the row is doing outranks selection, since a rail of sessions is read for
    // its state first. The tint deepens for the selected row so it is still the one the
    // eye lands on.
    private var rowFill: Color {
        let weight = selected ? 0.30 : hovering ? 0.22 : 0.16
        if busy { return Theme.dotOn.opacity(weight) }
        if finished { return Theme.attention.opacity(weight) }
        if selected { return Color.black.opacity(0.06) }
        return hovering ? Color.black.opacity(0.03) : .clear
    }
}

// What the session is doing right now, under its title. Most tool calls finish in a
// few milliseconds, so the line holds for a moment before it gives way: long enough
// to read, and only ever replaced by the next call rather than by an empty gap.
private struct ActivityLine: View {
    let activity: String?

    private static let minimumDwell: TimeInterval = 1

    @State private var shown: String?
    @State private var shownAt = Date.distantPast

    var body: some View {
        Group {
            if let shown {
                Text("↳ \(shown)")
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Arriving text is the news, so it lands at once; leaving text
                    // fades so the row does not blink.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: shown)
        // A newer value cancels the wait for the older one, which is what keeps the
        // hold from delaying anything the user would rather see.
        .task(id: activity) { await settle(on: activity) }
    }

    private func settle(on next: String?) async {
        let elapsed = Date().timeIntervalSince(shownAt)
        if shown != nil, elapsed < Self.minimumDwell {
            try? await Task.sleep(for: .seconds(Self.minimumDwell - elapsed))
            guard !Task.isCancelled else { return }
        }
        shown = next
        if next != nil { shownAt = Date() }
    }
}

// The small caps rail label that heads the project list.
private struct RailLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            SectionDot(size: 4.5)
            Text(text.uppercased())
                .font(.mono(10, .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
    }
}

// State as a word rather than a dot, so a glance down the rail reads as text.
private struct StatusPill: View {
    let text: String
    let running: Bool

    var body: some View {
        Text(text.uppercased())
            .font(.mono(9.5, .semibold))
            .kerning(0.5)
            .foregroundStyle(running ? AnyShapeStyle(Theme.addition) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(running ? Theme.dotOn.opacity(0.18) : Color.black.opacity(0.05)))
    }
}

// "2m", "3h", "2d": short enough to sit at the end of a narrow row.
private enum RelativeTime {
    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
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
