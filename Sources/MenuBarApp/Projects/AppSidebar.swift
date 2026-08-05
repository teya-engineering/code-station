import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the MCP config manager.
struct AppSidebar: View {
    let onConfigureServers: () -> Void
    let onOpenDocker: () -> Void
    let onOpenSettings: () -> Void
    let onOpenPostman: () -> Void
    let onReviewOldSessions: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings

    // A project is expanded by default while it is the selected one; anything the user
    // clicks on the disclosure arrow is remembered here and wins over that default.
    @State private var expansion: [UUID: Bool] = [:]
    @State private var renamingID: UUID?
    @State private var choosingSessionKind: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
        }
        .frame(width: 330)
        .background(Theme.sidebar)
        .sheet(item: $choosingSessionKind) { project in
            NewSessionView(project: project) { choice in
                startSession(choice, in: project)
            }
            .appOverlays()
        }
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
            if store.projects.isEmpty {
                Text("No projects yet. Add a folder and Claude Code will run right inside it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    // Keyed on what decides whether a session block is on screen, so the
                    // reveal plays wherever the change came from: a click on the project
                    // row, or the first session arriving under an already open one.
                    .animation(.easeOut(duration: 0.22), value: revealKey)
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
            isExpanded: expanded,
            isMissing: store.isMissing(project),
            sessionCount: sessions.count,
            runningCount: running,
            finishedCount: store.finishedCount(in: project.id),
            cost: sessions.reduce(0) { $0 + ($1.usage?.costUSD ?? 0) },
            isRenaming: renamingID == project.id,
            onNewSession: { requestNewSession(in: project) },
            onRename: { name in
                store.renameProject(project.id, to: name)
                renamingID = nil
            },
            onCancelRename: { renamingID = nil }
        )
        .contentShape(Rectangle())
        // Declared before the single tap so a double click resolves to a new session
        // rather than two expand toggles.
        .onTapGesture(count: 2) {
            store.selectedProjectID = project.id
            requestNewSession(in: project)
        }
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

        // An expanded project with nothing under it draws no block at all: an empty one
        // still carries its padding, which reads as the row shifting on every click.
        if expanded, !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sessions) { session in
                    let busy = runner.state(session.id).isBusy
                    let finished = store.hasFinished(session.id)
                    let changes = changes(session, project: project)
                    SessionCard(session: session,
                                selected: isSelected(session),
                                busy: busy,
                                finished: finished,
                                activity: activitySummary(session, project: project,
                                                          busy: busy, finished: finished),
                                added: changes.added,
                                removed: changes.removed,
                                branch: branch(session, project: project),
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
            }
            .padding(.top, 6)
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    private func isExpanded(_ project: Project) -> Bool {
        expansion[project.id] ?? (project.id == store.selectedProject?.id)
    }

    private var revealKey: [UUID: Int] {
        var key: [UUID: Int] = [:]
        for project in store.projects where isExpanded(project) {
            key[project.id] = store.sessions(for: project.id).count
        }
        return key
    }

    // MARK: - Creating and removing sessions

    // A git repository gets the folder-or-worktree choice; a plain folder has no
    // worktrees to offer, so the session is just created.
    private func requestNewSession(in project: Project) {
        guard FileManager.default.fileExists(atPath: project.path + "/.git") else {
            store.newSession(in: project.id)
            return
        }
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        switch choice {
        case .worktree(let sessionID): createWorktreeSession(in: project, id: sessionID)
        case .folder: store.newSession(in: project.id)
        }
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
                    SessionRemoval.remove(session, from: store)
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
    // it before the session exists, which is also what lets the sheet name both.
    private func createWorktreeSession(in project: Project, id sessionID: UUID) {
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

    // The line under a session's title. A running session shows the call in flight
    // ("Bash · swift build"); one that is not shows where it left off, which is the only
    // thing that says what a session is about without opening it.
    private func activitySummary(_ session: ChatSession, project: Project,
                                 busy: Bool, finished: Bool) -> String? {
        let root = session.worktreePath ?? project.path
        let tools = session.messages.flatMap(\.tools)
        if busy, let running = tools.last(where: { $0.isRunning }) {
            return toolLabel(running, root: root)
        }
        guard let last = tools.last(where: { !$0.isRunning }) else { return nil }
        return (finished ? "ended after " : "last: ") + toolLabel(last, root: root)
    }

    private func toolLabel(_ tool: ToolUse, root: String) -> String {
        let presentation = ToolPresentationCache.presentation(for: tool, projectPath: root)
        guard !presentation.argument.isEmpty else { return presentation.verb }
        return "\(presentation.verb) · \(presentation.argument)"
    }

    // Lines this session's edits have added and removed, summed over the whole
    // conversation. A rough measure, but enough to tell a session that wrote code from
    // one that only answered a question.
    private func changes(_ session: ChatSession, project: Project) -> (added: Int, removed: Int) {
        let root = session.worktreePath ?? project.path
        return session.messages.flatMap(\.tools).reduce(into: (added: 0, removed: 0)) { total, tool in
            guard !tool.isError, !tool.isRunning else { return }
            let presentation = ToolPresentationCache.presentation(for: tool, projectPath: root)
            total.added += presentation.added ?? 0
            total.removed += presentation.removed ?? 0
        }
    }

    // A worktree session owns its branch; anything else works on whatever the project
    // folder has checked out.
    private func branch(_ session: ChatSession, project: Project) -> String? {
        session.worktreeBranch ?? GitHead.branch(at: project.path)
    }

    private func isSelected(_ session: ChatSession) -> Bool {
        if case .session(let id) = store.selection { return id == session.id }
        return false
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !oldSessions.isEmpty { oldSessionsStrip }

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

            HStack(spacing: 8) {
                BottomRow(title: "MCP", action: onConfigureServers)
                BottomRow(title: "Docker", action: onOpenDocker)
                BottomRow(title: "Settings", action: onOpenSettings)
                BottomRow(title: "Postman", action: onOpenPostman)
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

    // Sessions pile up quietly, and the worktrees behind them take real disk. The strip
    // says how much has gone stale and hands it to a screen that explains what clearing
    // each one would cost; it never offers to do anything on its own.
    private var oldSessionsStrip: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(oldSessions.count) session\(oldSessions.count == 1 ? "" : "s") older than \(oldSessionDays) day\(oldSessionDays == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if oldWorktrees > 0 {
                    Text(oldWorktrees == 1 ? "one of them holds a worktree"
                                           : "\(oldWorktrees) of them hold worktrees")
                        .font(.mono(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: onReviewOldSessions) {
                Text("Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.035)))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var oldSessionDays: Int { appSettings.oldSessionDays }

    private var oldSessions: [ChatSession] {
        OldSessions.olderThan(oldSessionDays, in: store.sessions)
            .filter { !runner.state($0.id).isBusy }
    }

    private var oldWorktrees: Int {
        oldSessions.filter { $0.worktreePath != nil }.count
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
// rather than to work. Four across leaves each label little room, so it shrinks to fit
// rather than truncating: a clipped word reads as a bug, a slightly smaller one does not.
private struct BottomRow: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.mono(10, .semibold))
                .kerning(0.5)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

// One line per project: who it is on the left, what it has cost and how many sessions
// it holds on the right. The sessions themselves carry the detail, so the row stays a
// heading rather than competing with the cards under it.
private struct ProjectHeaderRow: View {
    let project: Project
    let isExpanded: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let cost: Double
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

            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
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
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if finishedCount > 0 {
                        FinishedDot()
                            .help(finishedCount == 1
                                  ? "A session here finished while you were away"
                                  : "\(finishedCount) sessions here finished while you were away")
                    }
                }
                Spacer(minLength: 8)
                // The name gives way before the numbers do: a truncated project name is
                // still recognisable, a truncated cost is not.
                Text(meta)
                    .font(.mono(11))
                    .foregroundStyle(isMissing ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .layoutPriority(1)

                // The chevron says which way the row goes; under the pointer it gives way
                // to the one thing you come to a project row to do. Both sit in a slot of
                // one width, so nothing beside them moves as the pointer arrives.
                ZStack(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(hovering ? 0 : isExpanded ? 0 : 1)
                    if hovering {
                        Button(action: onNewSession) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("New session")
                    }
                }
                .frame(width: 14, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isExpanded ? Color.black.opacity(0.05) : hovering ? Color.black.opacity(0.03) : .clear))
        .help(project.collapsedPath)
        .onHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }

    // What the project has spent and how much of it there is to open. The path is the
    // only thing that tells two projects of the same name apart, so it stays as the
    // row's tooltip.
    private var meta: String {
        let sessions = "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
        guard cost > 0 else { return sessions }
        return "\(Money.short(cost)) · \(sessions)"
    }
}

// The project's initial, tinted from its name, with the number of sessions running in
// it hanging off the corner.
private struct MonogramTile: View {
    let name: String
    let badge: Int

    var body: some View {
        let tint = Theme.monogram(for: name)
        RoundedRectangle(cornerRadius: 8)
            .fill(tint.opacity(0.14))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.mono(12, .semibold))
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

// A session as a card rather than a row: state at the top, what it is doing in the
// middle, what it has produced at the bottom. It is the unit of the sidebar, so it
// carries enough to decide whether to open it without opening it.
private struct SessionCard: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool
    let finished: Bool
    let activity: String?
    let added: Int
    let removed: Int
    let branch: String?
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StateDot(colour: stateColour, pulsing: busy)
                Text(stateWord)
                    .font(.mono(9.5, .semibold))
                    .kerning(0.6)
                    .foregroundStyle(stateColour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if session.worktreePath != nil {
                    StatusPill(text: "WT", running: false)
                        .help("Runs in its own git worktree")
                }
                Spacer(minLength: 6)
                // The timestamp hides in place rather than being taken out, so the header
                // is one width whether or not the pointer is on the card.
                ZStack(alignment: .trailing) {
                    Text(RelativeTime.short(session.lastActivity))
                        .font(.mono(10))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                    if hovering {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete session")
                    }
                }
            }

            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ActivityLine(activity: activity)

            // Only a running session gets a bar, and it is how full its context is: the
            // one number that says how much room the session has left to keep going.
            if busy {
                Meter(fraction: session.usage?.contextFraction ?? 0, colour: Theme.dotOn, height: 4)
                    .help("Context used")
                    .padding(.top, 1)
            }

            if hasFooter {
                HStack(spacing: 7) {
                    if added > 0 {
                        Text("+\(added)")
                            .font(.mono(11, .medium))
                            .foregroundStyle(Theme.addition)
                    }
                    if removed > 0 {
                        Text("-\(removed)")
                            .font(.mono(11, .medium))
                            .foregroundStyle(Theme.deletion)
                    }
                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.mono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let usage = session.usage, usage.turns > 0 {
                        Text("\(usage.turns) turn\(usage.turns == 1 ? "" : "s") · \(Money.short(usage.costUSD))")
                            .font(.mono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(cardStroke, lineWidth: bordered ? 1.5 : 1))
        .animation(.easeOut(duration: 0.25), value: [busy, finished])
        .onHover { hovering = $0 }
    }

    private var hasFooter: Bool {
        added > 0 || removed > 0 || branch != nil || (session.usage?.turns ?? 0) > 0
    }

    // What the card is doing outranks selection, since a column of sessions is read for
    // its state first.
    private var stateWord: String {
        if busy { return "Running" }
        if finished { return "Finished while away" }
        return "Idle"
    }

    private var stateColour: Color {
        if busy { return Theme.accent }
        if finished { return Theme.attention }
        return Color.secondary
    }

    private var bordered: Bool { busy || finished || selected }

    // A card that is doing something lifts off the sidebar onto white; the rest stay
    // flat so the running one is the only thing that catches the eye.
    private var cardFill: Color {
        if busy || finished || selected { return Theme.card }
        return hovering ? Color.black.opacity(0.05) : Color.black.opacity(0.035)
    }

    private var cardStroke: Color {
        if busy { return Theme.accent }
        if finished { return Theme.attention.opacity(0.7) }
        if selected { return Color.black.opacity(0.30) }
        return .clear
    }
}

// The state light at the top of a session card. It breathes while the session runs,
// which is the only movement in the sidebar and so reads as "this one is live".
private struct StateDot: View {
    let colour: Color
    let pulsing: Bool

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { _, running in dim = running }
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

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
private enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }
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
