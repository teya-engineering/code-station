import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the app's tools and settings.
struct AppSidebar: View {
    let skills: SkillsManager
    let tools: ToolsMenuActions
    let onReviewOldSessions: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(MobileAccessController.self) private var mobileAccess

    // A project is expanded by default while it is the selected one. Explicit choices
    // win over that default and are restored when the app opens again.
    @State private var expansion = Preferences.sidebarExpansion
    @State private var collapsedGroups = Preferences.collapsedSidebarGroups
    @State private var renamingID: UUID?
    @State private var choosingSessionKind: Project?
    @State private var choosingWorkspaceSession: ProjectWorkspace?
    @State private var showingNewWorkspace = false
    @State private var showingNewTask = false
    @State private var askingTask: Project?
    // A session opened away from its sidebar card and not brought into view yet. A card
    // clicked in the sidebar is already under the pointer, so it does not need this.
    @State private var sessionToReveal: UUID?
    @State private var sessionVisibility = SidebarSessionVisibility()
    @State private var filterText = ""
    @State private var oldSessionSummary = OldSessionSummary()
    @State private var hoveringHome = false
    @FocusState private var filterFocused: Bool

    private static let oldSessionRefreshInterval: Duration = .seconds(3_600)

    private struct OldSessionSummary: Equatable {
        var sessions = 0
        var worktrees = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
        }
        .frame(width: 318)
        .background(Theme.sidebar)
        .background(keyboardShortcuts)
        .task { await watchWorkingTrees() }
        .task(id: oldSessionDays) { await refreshOldSessionsHourly() }
        .onChange(of: store.sidebarSessions.count) { _, _ in refreshOldSessions() }
        .sheet(item: $choosingSessionKind) { project in
            NewSessionView(project: project) { choice in
                startSession(choice, in: project)
            }
            .appOverlays()
        }
        .sheet(item: $choosingWorkspaceSession) { workspace in
            NewWorkspaceSessionView(workspace: workspace) { choice in
                startWorkspaceSession(choice, in: workspace)
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView { workspace in
                setExpanded(true, for: workspace.id)
                choosingWorkspaceSession = workspace
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskView(onCreate: createTask)
                .appOverlays()
        }
        .taskRunSheet($askingTask) { task, values, note in
            startRun(task, values: values, note: note)
        }
    }

    // MARK: - Heading

    private var heading: some View {
        // Both rows read the same list, so it is worked out once for the pair rather than
        // built and sorted twice on every redraw of the rail.
        let notices = sessionNotices
        return VStack(alignment: .leading, spacing: 0) {
            brandBar(notices)
            needsYouCard(notices)
            filterBar
            arrangementBar
        }
    }

    private func brandBar(_ notices: [NoticedSession]) -> some View {
        let running = notices.count { $0.notice == .running }
        return HStack(spacing: 10) {
            Button(action: store.selectHome) {
                HStack(spacing: 9) {
                    AppMark()
                        .frame(width: 26, height: 26)
                    Text("Teya Code Station")
                        .font(.logo(18))
                        .kerning(-0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(store.selection == .home || hoveringHome ? Theme.card : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(store.selection == .home ? Theme.border : Color.clear, lineWidth: 1.3))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hoveringHome = $0 }
            .appTooltip("Home")

            Spacer(minLength: 4)

            // The count of what is running, which is the one number worth carrying at the
            // very top: it is the reason to look at the rail at all.
            if running > 0 {
                HStack(spacing: 5) {
                    RunningDot()
                    Text("\(running)")
                        .font(.mono(9.5, .semibold))
                        .kerning(0.7)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.1)))
                .appMenu { sessionNoticeMenu }
                .appTooltip("Show active and unread sessions")
            }

            MobileAccessBadge()
        }
        .padding(.horizontal, 14)
        .headerBand(Theme.sidebar)
    }

    // Permission prompts and turns that ended while the user was away are the only things
    // in the app that are waiting on a person, so they sit above the tree rather than
    // being found by opening the project they happen to belong to.
    @ViewBuilder private func needsYouCard(_ notices: [NoticedSession]) -> some View {
        let waiting = notices.filter { $0.notice != .running }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.attention).frame(width: 6, height: 6)
                    Text("NEEDS YOU · \(waiting.count)")
                        .font(.mono(9.5, .semibold))
                        .kerning(1.1)
                        .foregroundStyle(Theme.attentionText)
                    Spacer(minLength: 6)
                    Text("⌘⇧A")
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(waiting.prefix(3), id: \.session.id) { noticed in
                        needsYouRow(noticed)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(Theme.attention.opacity(0.45), lineWidth: 1.3))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func needsYouRow(_ noticed: NoticedSession) -> some View {
        // Answering means the pending prompt; reviewing means the files a finished turn
        // left behind, so the two land on different tabs of the same session.
        let answering = noticed.notice == .needsInput
        return HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(noticed.session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(noticed.reason)
                    .font(.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ActionButton(title: answering ? "Answer" : "Review",
                         height: 24, size: 11.5) {
                openNoticedSession(noticed.session)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openNoticedSession(noticed.session) }
    }

    // Narrows the list to the projects, workspaces and sessions that contain what is
    // typed. It filters rather than searches: the rail keeps its order and simply drops
    // the rows that do not match.
    private var filterBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects and sessions", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($filterFocused)
            if filterText.isEmpty {
                Text("⌘F")
                    .font(.mono(9.5))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appTooltip("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // The order and the grouping both decide the shape of the whole rail under them, so
    // they share one line above the list in the open rather than hiding behind a menu.
    private var arrangementBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(ProjectSort.allCases) { option in
                    ArrangementChip(title: option.label,
                                    hint: option.hint,
                                    selected: appSettings.projectSort == option) {
                        appSettings.projectSort = option
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                ForEach(ProjectGrouping.allCases) { option in
                    ArrangementChip(title: option.label,
                                    hint: option.hint,
                                    selected: appSettings.projectGrouping == option) {
                        appSettings.projectGrouping = option
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private struct NoticedSession {
        let session: ChatSession
        let project: Project
        let notice: SessionNotice
        // Why this one is here, in the few words that fit under its title: the tool that
        // is asking, or what the finished turn left behind.
        let reason: String
    }

    private var sessionNotices: [NoticedSession] {
        store.sidebarSessions.compactMap { session in
            guard let project = store.project(session.projectID) else { return nil }
            let question = runner.question(session.id)
            guard let notice = SessionNotice(
                isBusy: runner.state(session.id).isBusy,
                needsInput: question != nil,
                finishedUnseen: store.hasFinished(session.id)) else { return nil }
            return NoticedSession(session: session, project: project, notice: notice,
                                  reason: reason(notice, question: question, session: session))
        }
        .sorted {
            if $0.notice != $1.notice { return $0.notice.rawValue < $1.notice.rawValue }
            return $0.session.lastActivity > $1.session.lastActivity
        }
    }

    private func reason(_ notice: SessionNotice, question: PermissionRequest?,
                        session: ChatSession) -> String {
        switch notice {
        case .needsInput:
            guard let question else { return "waiting on an answer" }
            return question.isQuestion
                ? "question · \(question.title.lowercased())"
                : "permission · \(question.toolName.lowercased())"
        case .running:
            let tasks = runner.backgroundTasks(session.id)
            if !tasks.isEmpty { return "waiting for " + BackgroundTaskPhrase.of(tasks) }
            return session.summary.lastTool ?? "running"
        case .finished:
            let files = session.summary.added + session.summary.removed
            return files > 0
                ? "finished while away · +\(session.summary.added) −\(session.summary.removed)"
                : "finished while away"
        }
    }

    private var sessionNoticeMenu: [MenuEntry] {
        let notices = sessionNotices
        var entries: [MenuEntry] = []
        for (index, noticed) in notices.enumerated() {
            if index > 0, notices[index - 1].notice != noticed.notice {
                entries.append(.separator)
            }
            entries.append(.item(
                noticed.session.title,
                checked: isSelected(noticed.session),
                badge: noticed.notice.badge,
                badgeTint: noticed.notice.tint,
                subtitle: noticed.session.workspaceID.flatMap(store.workspace)?.name
                    ?? noticed.project.name,
                detail: RelativeTime.short(noticed.session.lastActivity)) {
                    openNoticedSession(noticed.session)
                })
        }
        return entries
    }

    private func openNoticedSession(_ session: ChatSession) {
        let containerID = session.workspaceID ?? session.projectID
        filterText = ""
        setExpanded(true, for: containerID)
        sessionVisibility.pin(session.id, in: containerID)
        store.selectSession(session.id)
        sessionToReveal = session.id
    }

    // MARK: - Projects

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.projects.isEmpty && store.workspaces.isEmpty {
                Text("No projects yet. Add a folder and Claude Code will run right inside it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            } else if orderedItems.isEmpty {
                Text("Nothing matches \"\(filterQuery)\".")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            } else {
                // Grouped once per redraw: every row below reads from this, and a
                // streaming reply redraws the rail on every token.
                let grouped = groupedSessions
                let workspaceGroups = groupedWorkspaceSessions
                ScrollViewReader { scroller in
                    ScrollView {
                        // Lazy so the rail costs what is on screen rather than what the
                        // app holds. Every card carries a hint, a menu and hover of its
                        // own, and off-screen ones would still be built and laid out on
                        // each redraw - a streaming reply redraws the rail on every token.
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(sections) { section in
                                if let group = section.group {
                                    SectionHeading(title: group.title,
                                                   count: section.items.count,
                                                   collapsed: collapsedGroups.contains(group)) {
                                        toggleCollapsed(group)
                                    }
                                }
                                if !isCollapsed(section) {
                                    ForEach(section.items) { item in
                                        switch item {
                                        case .project(let project):
                                            projectSection(project,
                                                           sessions: grouped[project.id] ?? [])
                                                .id(project.id)
                                        case .workspace(let workspace):
                                            workspaceSection(
                                                workspace,
                                                sessions: workspaceGroups[workspace.id] ?? [])
                                                .id(workspace.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        // Keyed on what decides whether a session block is on screen, so the
                        // transition plays wherever the change came from: a click on the
                        // project row, or the first session arriving under an open one.
                        // Easing out rather than a spring: the block must not overshoot its
                        // own height, or it opens onto a gap under the last card.
                        .animation(.easeOut(duration: 0.26),
                                   value: visibilityKey(grouped, workspaceGroups: workspaceGroups))
                        .animation(.easeOut(duration: 0.22),
                                   value: sessionOrderKey(grouped,
                                                          workspaceGroups: workspaceGroups))
                        .animation(.easeOut(duration: 0.22), value: appSettings.projectSort)
                        .animation(.easeOut(duration: 0.22), value: appSettings.projectGrouping)
                        .animation(.easeOut(duration: 0.22), value: collapsedGroups)
                        .animation(.easeOut(duration: 0.22), value: filterText)
                    }
                    .task(id: sessionToReveal) { await reveal(with: scroller) }
                    .task(id: store.projectToReveal) { await revealProject(with: scroller) }
                }
            }
        }
    }

    private var sections: [SidebarSection] {
        appSettings.projectGrouping.sections(of: orderedItems)
    }

    private var filter: SidebarFilter { SidebarFilter(filterText) }

    private var filterQuery: String { filter.query }

    private var isFiltering: Bool { filter.isActive }

    private func matchesName(_ item: SidebarItem, _ filter: SidebarFilter) -> Bool {
        switch item {
        case .project:
            return filter.matches(name: item.name)
        case .workspace(let workspace):
            return filter.matches(name: item.name,
                                  orAnyOf: workspace.projectIDs.compactMap(store.project).map(\.name))
        }
    }

    private func containerID(of session: ChatSession) -> UUID {
        session.workspaceID ?? session.projectID
    }

    private var orderedItems: [SidebarItem] {
        let items = store.projects.map(SidebarItem.project)
            + store.workspaces.map(SidebarItem.workspace)
        let ordered = appSettings.projectSort.apply(to: items, sessions: store.sidebarSessions)
        let filter = self.filter
        guard filter.isActive else { return ordered }
        // A row stays when it matches itself, and also when it holds a session that does:
        // a session is only reachable through the row it lives under.
        return ordered.filter { item in
            matchesName(item, filter) || store.sidebarSessions.contains { session in
                containerID(of: session) == item.id && filter.matches(session)
            }
        }
    }

    // Every session under its project, most recently active first - the order the cards
    // are drawn in. The counts on a project row read from this, so it stays whole even
    // while a filter is on; the filter narrows the cards, not what the project holds.
    private var groupedSessions: [UUID: [ChatSession]] {
        var groups = Dictionary(grouping: store.sidebarSessions.filter { $0.workspaceID == nil },
                                by: \.projectID)
        for key in groups.keys { groups[key]?.sort { $0.lastActivity > $1.lastActivity } }
        return groups
    }

    private var groupedWorkspaceSessions: [UUID: [ChatSession]] {
        let groups = Dictionary(grouping: store.sidebarSessions.compactMap { session in
            session.workspaceID.map { ($0, session) }
        }, by: \.0)
        return groups.mapValues { rows in
            rows.map(\.1).sorted { $0.lastActivity > $1.lastActivity }
        }
    }

    private func workspaceSection(_ workspace: ProjectWorkspace,
                                  sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(workspace)
        let visible = visibleSessions(sessions, in: workspace.id)
        let running = sessions.count { runner.state($0.id).isBusy }
        let projects = workspace.projectIDs.compactMap(store.project)

        return VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeaderRow(
                workspace: workspace,
                projects: projects,
                selected: store.selection == .workspace(workspace.id),
                isExpanded: expanded && !visible.isEmpty,
                sessionCount: sessions.count,
                runningCount: running,
                finishedCount: store.finishedCount(inWorkspace: workspace.id),
                isRenaming: renamingID == workspace.id,
                onNewSession: { choosingWorkspaceSession = workspace },
                onRename: { name in
                    store.renameWorkspace(workspace.id, to: name)
                    renamingID = nil
                },
                onCancelRename: { renamingID = nil }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectWorkspace(workspace.id)
                setExpanded(!expanded, for: workspace.id)
                if expanded { sessionVisibility.reset(workspace.id) }
            }
            .appContextMenu {
                [.item("Rename…") { renamingID = workspace.id },
                 .item("New session") { choosingWorkspaceSession = workspace },
                 .separator,
                 .item("Delete workspace", kind: .destructive) {
                     confirmRemoveWorkspace(workspace)
                 }]
            }

            if expanded, !visible.isEmpty {
                let tint = Theme.workspaceTint
                SidebarRail(colour: tint.colour) {
                    ForEach(visible) { session in
                        if let lead = store.project(session.projectID) {
                            let busy = runner.state(session.id).isBusy
                            let finished = store.hasFinished(session.id)
                            let folders = store.workingDirectories(for: session)
                            let selected = isSelected(session)
                            SidebarRailRow(colour: tint.colour,
                                           selectedColour: tint.ink,
                                           selected: selected) {
                                SessionCard(session: session,
                                            selected: selected,
                                            busy: busy,
                                            waiting: runner.state(session.id) == .waiting,
                                            needsInput: runner.question(session.id) != nil,
                                            finished: finished,
                                            activity: activitySummary(session, project: lead,
                                                                      busy: busy, finished: finished),
                                            added: session.summary.added,
                                            removed: session.summary.removed,
                                            branch: workspaceBranch(session),
                                            uncommitted: folders.contains(where: workingTrees.isDirty),
                                            connected: mobileAccess.isConnected(session: session.id),
                                            isRenaming: renamingID == session.id,
                                            onDelete: { confirmRemoveSession(session) },
                                            onRename: { name in
                                                store.renameSession(session.id, to: name)
                                                renamingID = nil
                                            },
                                            onCancelRename: { renamingID = nil })
                            }
                                .contentShape(Rectangle())
                                .onTapGesture { store.selectSession(session.id) }
                                .appContextMenu {
                                    [.item("Rename…") { renamingID = session.id },
                                     .separator,
                                     .item("Delete session", kind: .destructive) {
                                         confirmRemoveSession(session)
                                     }]
                                }
                        }
                    }
                    // The rest of a filtered list is what did not match, so there is
                    // nothing to unfold.
                    let hidden = isFiltering ? 0 : sessions.count - visible.count
                    if hidden > 0 {
                        SidebarRailRow(colour: tint.colour) {
                            SeeMoreCard(title: "See \(hidden) more…") {
                                sessionVisibility.showAll(workspace.id)
                            }
                        }
                    }
                }
                .transition(.fadeIn)
            }
        }
    }

    private func workspaceBranch(_ session: ChatSession) -> String? {
        let checkouts = store.checkoutProjects(for: session)
        let branches = checkouts.compactMap(\.worktreeBranch)
        guard let first = branches.first else {
            return "\(checkouts.count) projects"
        }
        return branches.allSatisfy { $0 == first }
            ? "\(first) · \(checkouts.count) repos"
            : "\(checkouts.count) repos"
    }

    private func projectSection(_ project: Project, sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(project)
        let visible = visibleSessions(sessions, in: project.id)
        let running = sessions.count { runner.state($0.id).isBusy }

        // The row and its sessions are one stack so the gap between them belongs to the
        // block that changes size. An outer spacing would remain after the block leaves,
        // which reads as the row jumping at the end of the close.
        return VStack(alignment: .leading, spacing: 0) {
            ProjectHeaderRow(
                project: project,
                selected: store.selection == nil && store.selectedProjectID == project.id,
                isExpanded: expanded && !visible.isEmpty,
                isMissing: store.isMissing(project),
                sessionCount: sessions.count,
                runningCount: running,
                finishedCount: store.finishedCount(in: project.id),
                // A project can hold sessions from either agent, so the total only counts
                // the ones whose agent is set to show what it spends.
                cost: sessions.reduce(0) { total, session in
                    guard appSettings.showsCost(for: session.agent) else { return total }
                    return total + (session.usage?.costUSD ?? 0)
                },
                clearableCount: sessions.count - running,
                canRunTask: running == 0,
                isRenaming: renamingID == project.id,
                onNewSession: { requestNewSession(in: project) },
                onRunTask: { runTask(project) },
                onClearSessions: { confirmClearSessions(in: project) },
                onRename: { name in
                    store.renameProject(project.id, to: name)
                    renamingID = nil
                },
                onCancelRename: { renamingID = nil }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectProject(project.id)
                setExpanded(!expanded, for: project.id)
                // Closing a project puts its list away, and putting it away includes the
                // tail the user had unfolded: the next open starts back at the cap.
                if expanded { sessionVisibility.reset(project.id) }
            }
            .appContextMenu { headerMenu(project) }

            // An expanded project with nothing under it draws no block at all: an empty one
            // still carries its padding, which reads as the row shifting on every click.
            if expanded, !visible.isEmpty {
                let tint = Theme.projectTint(for: project.name)
                SidebarRail(colour: tint.colour) {
                    ForEach(visible) { session in
                        let busy = runner.state(session.id).isBusy
                        let finished = store.hasFinished(session.id)
                        let selected = isSelected(session)
                        SidebarRailRow(colour: tint.colour,
                                       selectedColour: tint.ink,
                                       selected: selected) {
                            SessionCard(session: session,
                                        selected: selected,
                                        busy: busy,
                                        waiting: runner.state(session.id) == .waiting,
                                        needsInput: runner.question(session.id) != nil,
                                        finished: finished,
                                        activity: activitySummary(session, project: project,
                                                                  busy: busy, finished: finished),
                                        added: session.summary.added,
                                        removed: session.summary.removed,
                                        branch: branch(session, project: project),
                                        uncommitted: workingTrees.isDirty(folder(session, project: project)),
                                        connected: mobileAccess.isConnected(session: session.id),
                                        isRenaming: renamingID == session.id,
                                        onDelete: { confirmRemoveSession(session) },
                                        onRename: { name in
                                            store.renameSession(session.id, to: name)
                                            renamingID = nil
                                        },
                                        onCancelRename: { renamingID = nil })
                        }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectSession(session.id)
                            }
                            .appContextMenu {
                                [.item("Rename…") { renamingID = session.id },
                                 .separator,
                                 .item("Delete session", kind: .destructive) {
                                     confirmRemoveSession(session)
                                 }]
                            }
                    }
                    let hidden = isFiltering ? 0 : sessions.count - visible.count
                    if hidden > 0 {
                        SidebarRailRow(colour: tint.colour) {
                            SeeMoreCard(title: "See \(hidden) more…") {
                                sessionVisibility.showAll(project.id)
                            }
                        }
                    }
                }
                .transition(.fadeIn)
            }
        }
    }

    // Tasks and projects share the row but not its menu: a task is run rather than
    // started, and deleting it takes its app-owned folder along.
    private func headerMenu(_ project: Project) -> [MenuEntry] {
        if project.kind == .adHoc {
            return [.item("Run task") { runTask(project) },
                    .item("Rename…") { renamingID = project.id },
                    .separator,
                    .item("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    },
                    .item("Open in \(SystemTerminal.appName)") { openInTerminal(project) },
                    .separator,
                    .item("Clear idle runs", kind: .destructive) { confirmClearSessions(in: project) },
                    .item("Delete task", kind: .destructive) { confirmRemoveProject(project) }]
        }
        return [.item("Rename…") { renamingID = project.id },
                .item("New session") { requestNewSession(in: project) },
                .separator,
                .item("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                },
                .item("Open in \(SystemTerminal.appName)") { openInTerminal(project) },
                .separator,
                .item("Clear idle sessions", kind: .destructive) { confirmClearSessions(in: project) },
                .item("Remove project", kind: .destructive) { confirmRemoveProject(project) }]
    }

    // A filter is asking to see what matched, so it opens every row that survived it. A
    // closed row would hide the very sessions the filter kept.
    private func isExpanded(_ project: Project) -> Bool {
        guard !isFiltering else { return true }
        let selectedProjectID: UUID? = switch store.selection {
        case .session(let id): store.sidebarSession(id)?.projectID
        case .home, .workspace: nil
        case nil: store.selectedProjectID
        }
        return expansion[project.id] ?? (project.id == selectedProjectID)
    }

    private func isExpanded(_ workspace: ProjectWorkspace) -> Bool {
        isFiltering || (expansion[workspace.id] ?? true)
    }

    private func setExpanded(_ isExpanded: Bool, for id: UUID) {
        expansion[id] = isExpanded
        Preferences.sidebarExpansion = expansion
        // Opening a row inside a folded section unfolds the section as well, or the row
        // would be opened somewhere the user cannot see it.
        if isExpanded { showGroup(containing: id) }
    }

    // A folded section is drawn as its heading alone. The filter overrides it: a search
    // is asking to see what matched, so a match is never hidden behind a heading.
    private func isCollapsed(_ section: SidebarSection) -> Bool {
        guard let group = section.group, !isFiltering else { return false }
        return collapsedGroups.contains(group)
    }

    private func toggleCollapsed(_ group: SidebarGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
        Preferences.collapsedSidebarGroups = collapsedGroups
    }

    private func showGroup(containing id: UUID) {
        let item = store.project(id).map(SidebarItem.project)
            ?? store.workspace(id).map(SidebarItem.workspace)
        guard let group = item?.group, collapsedGroups.remove(group) != nil else { return }
        Preferences.collapsedSidebarGroups = collapsedGroups
    }

    // A list stays capped at its chosen number of sessions unless the user unfolded it with
    // see-more, so a new session pushes the last visible one below the fold. A filtered
    // list is drawn whole instead: it is already short, and a match left under see-more
    // reads as the filter having missed it.
    private func visibleSessions(_ sessions: [ChatSession], in containerID: UUID) -> [ChatSession] {
        let filter = self.filter
        guard filter.isActive else {
            return sessionVisibility.visible(
                sessions, in: containerID, limit: appSettings.sidebarSessionLimit)
        }
        return filter.matchingSessions(in: sessions)
    }

    // Keyed on the cards that are drawn rather than the sessions that exist, so the
    // fade plays for see-more the same as for a session arriving or leaving.
    private func visibilityKey(_ grouped: [UUID: [ChatSession]],
                               workspaceGroups: [UUID: [ChatSession]]) -> [UUID: Int] {
        var key: [UUID: Int] = [:]
        for project in store.projects where isExpanded(project) {
            key[project.id] = visibleSessions(grouped[project.id] ?? [], in: project.id).count
        }
        for workspace in store.workspaces where isExpanded(workspace) {
            key[workspace.id] = visibleSessions(
                workspaceGroups[workspace.id] ?? [], in: workspace.id).count
        }
        return key
    }

    private func sessionOrderKey(_ grouped: [UUID: [ChatSession]],
                                 workspaceGroups: [UUID: [ChatSession]]) -> [UUID] {
        store.workspaces.flatMap { workspaceGroups[$0.id, default: []].map(\.id) }
            + store.projects.flatMap { grouped[$0.id, default: []].map(\.id) }
    }

    // Brings a session opened away from the rail into view. It scrolls to the project or
    // workspace rather than to the card, so the session stays visible in its full context.
    // Creating a session can also reorder the list under the recent sort, which may move
    // its project off screen.
    private func reveal(with scroller: ScrollViewProxy) async {
        guard let id = sessionToReveal, let session = store.session(id) else { return }
        // The card is created by the same change that asked for this, so the list has to be
        // laid out again before there is anything to scroll to.
        await Task.yield()
        withAnimation(.easeOut(duration: 0.26)) {
            scroller.scrollTo(session.workspaceID ?? session.projectID, anchor: .top)
        }
        sessionToReveal = nil
    }

    // Brings a project opened away from the rail into view. The row has to be drawn
    // before it can be scrolled to, so a filter narrow enough to hide it is dropped and
    // a folded section is unfolded first.
    private func revealProject(with scroller: ScrollViewProxy) async {
        guard let id = store.projectToReveal, store.project(id) != nil else { return }
        if !orderedItems.contains(where: { $0.id == id }) { filterText = "" }
        showGroup(containing: id)
        await Task.yield()
        withAnimation(.easeOut(duration: 0.26)) {
            scroller.scrollTo(id, anchor: .top)
        }
        store.projectToReveal = nil
    }

    // MARK: - Creating and removing sessions

    private func requestNewSession(in project: Project) {
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        // A collapsed project keeps its new session hidden, and starting work in a project
        // is the clearest sign yet that it wants to be open.
        setExpanded(true, for: project.id)
        switch choice {
        case .worktree(let sessionID, let base, let agent, let model, let agentAvatarName):
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent,
                                  model: model, agentAvatarName: agentAvatarName)
        case .folder(let agent, let model, let agentAvatarName):
            switch store.insertSession(in: project.id, agent: agent, model: model,
                                       agentAvatarName: agentAvatarName) {
            case .success(let session):
                sessionToReveal = session.id
            case .failure(let failure):
                showLifecycleFailure(SessionLifecycle.Failure(
                    title: "Could not create the session", message: failure.message))
            }
        }
    }

    // Worktrees are created as one transaction from the user's point of view. If any
    // repository fails, the ones already created are removed before the error is shown.
    private func startWorkspaceSession(_ choice: WorkspaceSessionChoice,
                                       in workspace: ProjectWorkspace) {
        setExpanded(true, for: workspace.id)
        Task {
            switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store) {
            case .success:
                sessionToReveal = choice.sessionID
            case .failure(let failure):
                showLifecycleFailure(failure)
            }
        }
    }

    private func confirmRemoveSession(_ session: ChatSession) {
        let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
        let dirty = worktrees.count { workingTrees.isDirty($0) }
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: worktrees.isEmpty
                ? "Its conversation history is removed from the app."
                : "Its \(worktrees.count) worktree\(worktrees.count == 1 ? "" : "s") go with it."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits."),
            actions: [
                .init(label: worktrees.isEmpty ? "Delete session" : "Delete session and worktrees",
                      kind: .destructive) {
                    removeSessions([session])
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // Clearing a project keeps whatever is still running and takes the rest, worktrees
    // included. The message counts the worktrees separately: they are the part of this
    // that touches disk, and the part that can take uncommitted work with it.
    private func confirmClearSessions(in project: Project) {
        let idle = idleSessions(in: project)
        guard !idle.isEmpty else { return }
        let worktrees = idle.count { $0.worktreePath != nil }
        let dirty = idle.count { $0.worktreePath.map(workingTrees.isDirty) ?? false }
        let kept = store.standaloneSessions(for: project.id).count - idle.count
        var message = "Their conversation history is removed from the app."
        if worktrees > 0 {
            message = "\(worktrees) of them ran in a worktree. Uncommitted changes there are lost, and branches are kept only where they have unmerged commits."
        }
        if dirty > 0 {
            message += " \(dirty) of those worktree\(dirty == 1 ? " has" : "s have") uncommitted changes right now."
        }
        if kept > 0 {
            message += " The \(kept) still running stay\(kept == 1 ? "s" : "")."
        }
        dialogs.show(Dialog(
            title: "Clear \(idle.count) session\(idle.count == 1 ? "" : "s") from \(project.name)?",
            message: message,
            actions: [
                .init(label: "Clear sessions", kind: .destructive) {
                    removeSessions(idle)
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func idleSessions(in project: Project) -> [ChatSession] {
        store.standaloneSessions(for: project.id).filter { !runner.state($0.id).isBusy }
    }

    private func confirmRemoveProject(_ project: Project) {
        ProjectRemoval.confirm(project, in: store, runner: runner, shortcuts: shortcuts,
                               dialogs: dialogs)
    }

    private func confirmRemoveWorkspace(_ workspace: ProjectWorkspace) {
        let affected = sessions(in: workspace.id)
        let count = affected.count
        dialogs.show(Dialog(
            title: "Delete \(workspace.name)?",
            message: "This drops \(count) session\(count == 1 ? "" : "s") and removes their worktrees. The \(workspace.projectIDs.count) projects it groups stay.",
            actions: [
                .init(label: "Delete workspace", kind: .destructive) {
                    removeSessions(affected) { store.removeWorkspace(workspace.id) }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // The session id is chosen up front so the worktree folder and branch can carry
    // it before the session exists, which is also what lets the sheet name both.
    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       agent: AgentKind, model: String?, agentAvatarName: String?) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agent: agent, model: model,
                agentAvatarName: agentAvatarName, store: store) {
            case .success:
                sessionToReveal = sessionID
            case .failure(let failure):
                showLifecycleFailure(failure)
            }
        }
    }

    private func removeSessions(_ sessions: [ChatSession], onSuccess: (() -> Void)? = nil) {
        Task {
            var failures: [SessionLifecycle.Failure] = []
            for session in sessions {
                if case .failure(let failure) = await SessionLifecycle.remove(
                    session, from: store, runner: runner) {
                    failures.append(failure)
                }
            }
            guard failures.isEmpty else {
                showLifecycleFailure(SessionLifecycle.Failure(
                    title: failures.count == 1
                        ? failures[0].title
                        : "Could not delete some sessions",
                    message: failures.map(\.message).joined(separator: "\n")))
                return
            }
            onSuccess?()
        }
    }

    private func showLifecycleFailure(_ failure: SessionLifecycle.Failure) {
        dialogs.show(Dialog(title: failure.title, message: failure.message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }

    private func sessions(in workspaceID: UUID) -> [ChatSession] {
        store.sidebarSessions.filter { $0.workspaceID == workspaceID }
    }

    // The line under a session's title. A running session shows the call in flight
    // ("Bash · swift build"), which the runner keeps while the turn is alive. Everything
    // else reads from the saved summary, so the rail never observes transcript writes.
    private func activitySummary(_ session: ChatSession, project: Project,
                                 busy: Bool, finished: Bool) -> String? {
        let tasks = runner.backgroundTasks(session.id)
        if !tasks.isEmpty { return "waiting for " + BackgroundTaskPhrase.of(tasks) }
        if busy, let running = runner.runningTool(session.id) {
            let root = folder(session, project: project)
            return ToolPresentationCache.presentation(for: running, projectPath: root).label
        }
        guard let last = session.summary.lastTool else { return nil }
        return (finished ? "ended after " : "last: ") + last
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

    // MARK: - Uncommitted work

    // Only the folders behind cards that are on screen are looked at, and the list is
    // rebuilt on every pass so opening a project starts watching what it holds.
    private func watchWorkingTrees() async {
        while !Task.isCancelled {
            workingTrees.refresh(watchedFolders)
            try? await Task.sleep(for: WorkingTreeWatch.interval)
        }
    }

    private var watchedFolders: Set<String> {
        var folders: Set<String> = []
        let grouped = groupedSessions
        for project in store.projects where isExpanded(project) {
            for session in visibleSessions(grouped[project.id] ?? [], in: project.id) {
                folders.insert(folder(session, project: project))
            }
        }
        let workspaceGroups = groupedWorkspaceSessions
        for workspace in store.workspaces where isExpanded(workspace) {
            for session in visibleSessions(
                workspaceGroups[workspace.id] ?? [], in: workspace.id) {
                folders.formUnion(store.workingDirectories(for: session))
            }
        }
        return folders
    }

    // Where a session's files actually are: its own worktree, or the project folder it
    // shares with every other session that has no worktree.
    private func folder(_ session: ChatSession, project: Project) -> String {
        session.worktreePath ?? project.path
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if oldSessionSummary.sessions > 0 { oldSessionsStrip(oldSessionSummary) }

            HStack(spacing: 8) {
                ActionButton(title: "Add", height: 38, size: 13, fills: true)
                    .appMenu(edge: .top, matchWidth: true, addMenu)
                    .accessibilityLabel("Add a project, workspace, or task")

                SettingsButton(showsUpdate: skills.updateCount > 0)
                    .toolsMenu(tools, skills: skills, edge: .top)
            }

            if !runner.available {
                Text("\(runner.agent.title) was not found on PATH.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // Sessions pile up quietly, and the worktrees behind them take real disk. The strip
    // says how much has gone stale and hands it to a screen that explains what clearing
    // each one would cost; it never offers to do anything on its own.
    private func oldSessionsStrip(_ summary: OldSessionSummary) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.sessions) session\(summary.sessions == 1 ? "" : "s") older than \(oldSessionDays) day\(oldSessionDays == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if summary.worktrees > 0 {
                    Text(summary.worktrees == 1 ? "one worktree remains"
                                                : "\(summary.worktrees) worktrees remain")
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            InlineLink(title: "Review", action: onReviewOldSessions)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
    }

    private var oldSessionDays: Int { appSettings.oldSessionDays }

    private func refreshOldSessions() {
        let sessions = OldSessions.olderThan(oldSessionDays, in: store.sidebarSessions)
            .filter { !runner.state($0.id).isBusy }
        let worktrees = sessions.reduce(0) { count, session in
            count + store.checkoutProjects(for: session).compactMap(\.worktreePath).count
        }
        oldSessionSummary = OldSessionSummary(sessions: sessions.count, worktrees: worktrees)
    }

    private func refreshOldSessionsHourly() async {
        while !Task.isCancelled {
            refreshOldSessions()
            do {
                try await Task.sleep(for: Self.oldSessionRefreshInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - Actions

    private func addMenu() -> [MenuEntry] {
        return [
            .item("Add project", icon: "folder.badge.plus",
                  subtitle: "Choose an existing folder.", action: addProject),
            .item("Create workspace", icon: "square.stack.3d.up.fill",
                  subtitle: "Group two or more projects.") {
                showingNewWorkspace = true
            },
            .item("New task", icon: "bolt.fill",
                  subtitle: "A saved prompt you can run any time.") {
                showingNewTask = true
            }
        ]
    }

    // The shortcuts the whole window answers. They live on the sidebar because everything
    // they reach - the filter field, the first item waiting on a person, the project a new
    // session would start in - is here.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { startSessionInSelection() }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { jumpToFirstNeedingAttention() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .opacity(0)
    }

    private func jumpToFirstNeedingAttention() {
        guard let first = sessionNotices.first(where: { $0.notice != .running })
            ?? sessionNotices.first else { return }
        openNoticedSession(first.session)
    }

    // Whatever a new session would belong to right now: the selected project or
    // workspace, or the one holding the session on screen.
    private enum Container {
        case project(Project)
        case workspace(ProjectWorkspace)
    }

    private var selectedContainer: Container? {
        switch store.selection {
        case .workspace(let id):
            return store.workspace(id).map(Container.workspace)
        case .session(let id):
            guard let session = store.sidebarSession(id) else { return nil }
            if let workspaceID = session.workspaceID, let workspace = store.workspace(workspaceID) {
                return .workspace(workspace)
            }
            return store.project(session.projectID).map(Container.project)
        case .home:
            return nil
        case nil:
            return store.selectedProject.map(Container.project)
        }
    }

    private func startSessionInSelection() {
        switch selectedContainer {
        case .project(let project):
            // New work in a task means another run of its prompt, not an empty session.
            if project.kind == .adHoc {
                runTask(project)
            } else {
                requestNewSession(in: project)
            }
        case .workspace(let workspace):
            choosingWorkspaceSession = workspace
        case nil:
            // Nothing is selected, so there is no folder to start in yet.
            addProject()
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder Claude Code should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A folder that is already a project comes back as nil, and the store has
        // pointed itself at the existing one. Either way the rail lands on that project:
        // the list is ordered by the sort setting, so a project can be added anywhere
        // in it, including off screen.
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        setExpanded(true, for: id)
        filterText = ""
        store.selectProject(id, revealingInSidebar: true)
    }

    // Creating a task lands on its screen rather than in a session: the task is the
    // thing that was made, and running it is its own click - unless it was asked for.
    private func createTask(_ draft: NewTaskDraft) {
        switch store.addTask(named: draft.name, prompt: draft.prompt) {
        case .success(let project):
            setExpanded(true, for: project.id)
            filterText = ""
            store.selectProject(project.id, revealingInSidebar: true)
            if draft.runNow { runTask(project) }
        case .failure(let failure):
            dialogs.show(Dialog(
                title: "Could not create the task",
                message: failure.message,
                actions: [.init(label: "OK", kind: .cancel)]))
        }
    }

    // A task whose prompt has holes in it asks for them first; one that runs as written
    // starts on the click.
    private func runTask(_ project: Project) {
        if TaskRun.needsInput(project) {
            askingTask = project
        } else {
            startRun(project, values: [:], note: "")
        }
    }

    private func startRun(_ project: Project, values: [String: String], note: String) {
        setExpanded(true, for: project.id)
        switch TaskRun.run(project, values: values, note: note, store: store, runner: runner,
                           agentAvatarName: appSettings.defaultAgentAvatarName) {
        case .success(let session):
            sessionToReveal = session.id
        case .failure(let failure):
            showLifecycleFailure(SessionLifecycle.Failure(
                title: "Could not run the task", message: failure.message))
        }
    }

    private func openInTerminal(_ project: Project) {
        SystemTerminal.open(project.url)
    }
}

// MARK: - Rows

// The square that closes the footer row. Everything the app can be set up with lives
// behind it, so the rail beside it belongs entirely to the projects.
private struct SettingsButton: View {
    let showsUpdate: Bool

    @State private var hovering = false

    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.field : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .overlay(alignment: .topTrailing) {
                if showsUpdate { UpdateIndicator().offset(x: 3, y: -3) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .appTooltip("Tools and settings")
            .onHover { hovering = $0 }
            .accessibilityLabel("Tools and settings")
    }
}

// Each pair sits on a shared track and the chosen option is lifted out of it, so which is
// on reads from the shape alone without having to read the words.
private struct ArrangementChip: View {
    let title: String
    let hint: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.mono(9.5, .semibold))
                .kerning(0.6)
                .foregroundStyle(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Theme.card : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip(hint)
    }
}

// The label over one run of the rail, and the way to fold that run away. It is a quiet
// line rather than a card, so the rows under it stay the thing being read: the chevron
// only comes out under the pointer, and the count only while the run is folded, since a
// folded heading is the only thing left saying what is in there.
private struct SectionHeading: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Text(title.uppercased())
                    .font(.mono(9, .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                if collapsed {
                    Text("\(count)")
                        .font(.mono(9, .semibold))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 8)
                    .opacity(hovering || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .appTooltip(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }
}

// One line per workspace. The stacked tile distinguishes it from a single project without
// introducing another icon language into the sidebar.
private struct WorkspaceHeaderRow: View {
    let workspace: ProjectWorkspace
    let projects: [Project]
    let selected: Bool
    let isExpanded: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let isRenaming: Bool
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            ProjectTileView(name: workspace.name, tint: Theme.workspaceTint, stacked: true)

            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .focused($focused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                HStack(spacing: 5) {
                    Text(workspace.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if finishedCount > 0 { FinishedDot() }
                }

                Spacer(minLength: 6)

                ZStack(alignment: .trailing) {
                    HStack(spacing: 6) {
                        if runningCount > 0 { RunningDot() }
                        Text("\(projects.count) projects")
                            .font(.mono(10))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(hovering ? 0 : 1)

                    if hovering {
                        RowAction(icon: "plus", title: "New", action: onNewSession)
                            .appTooltip("New multi-project session")
                    }
                }
                .frame(minWidth: 62, alignment: .trailing)
            }
        }
        .appTooltip {
            Tooltip(
                title: workspace.name,
                subtitle: projects.map(\.name).joined(separator: " + "),
                rows: [Tooltip.Row(label: "Sessions", value: "\(sessionCount)"),
                       Tooltip.Row(label: "Projects", value: "\(projects.count)")])
        }
        .onPointerHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = workspace.name
            focused = true
        }
    }
}

// The shape both container rows wear. Selection is white with a ring; being merely open
// is the quieter fill, so an expanded project does not compete with the selected one.
// Open means a block is drawn below, not that the flag is set: a row with nothing under
// it wears the plain fill, or the tint reads as a state the row does not have.
private struct TreeRow<Content: View>: View {
    let selected: Bool
    let isExpanded: Bool
    let hovering: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 9) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Color.primary.opacity(0.28) : .clear, lineWidth: 1.3))
    }

    private var fill: Color {
        if selected { return Theme.card }
        if isExpanded { return Theme.field }
        return hovering ? Theme.sunken : .clear
    }
}

// One line per project: who it is, and the way in. The sessions themselves carry the
// detail, so the row stays a heading rather than competing with the cards under it, and
// its numbers live in the hint where they cost the line no room.
private struct ProjectHeaderRow: View {
    let project: Project
    let selected: Bool
    let isExpanded: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let cost: Double
    let clearableCount: Int
    let canRunTask: Bool
    let isRenaming: Bool
    let onNewSession: () -> Void
    let onRunTask: () -> Void
    let onClearSessions: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var isTask: Bool { project.kind == .adHoc }

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            ProjectTileView(name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            dashed: project.kind == .adHoc)

            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
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
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let schedule = project.task?.schedule, schedule.isActive {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(schedule.isWaitingForConfirmation
                                             ? Theme.attentionText : Theme.accent)
                            .appTooltip(schedule.isWaitingForConfirmation
                                ? "Timer waiting for confirmation"
                                : schedule.summary)
                    }
                    if finishedCount > 0 { FinishedDot() }
                }
                Spacer(minLength: 6)

                // The count says what the row holds; under the pointer it gives way to the
                // two things you come to a project row to do. The buttons carry their word
                // beside the glyph, so they take more room than the count did: the name
                // gives way while the pointer is on the row, which costs nothing to read
                // since the pointer is here for the buttons.
                ZStack(alignment: .trailing) {
                    HStack(spacing: 6) {
                        if runningCount > 0 { RunningDot() }
                        Text("\(sessionCount)")
                            .font(.mono(10))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(hovering ? 0 : 1)

                    if hovering {
                        HStack(spacing: 10) {
                            // A running session is doing work nobody asked to throw away,
                            // so the bin is only offered once there is something idle to
                            // clear.
                            if clearableCount > 0 {
                                RowAction(icon: "trash", title: "Delete", action: onClearSessions)
                                    .appTooltip("Clear \(clearableCount) idle session\(clearableCount == 1 ? "" : "s")")
                            }
                            // A task is run with its saved prompt rather than opened
                            // empty. The button waits while a run is still working in
                            // the task's folder.
                            if isTask {
                                if canRunTask {
                                    RowAction(icon: "play.fill", title: "Run", action: onRunTask)
                                        .appTooltip("Run the task's saved prompt in a fresh session")
                                }
                            } else {
                                RowAction(icon: "plus", title: "New", action: onNewSession)
                                    .appTooltip("New session")
                            }
                        }
                        .fixedSize()
                    }
                }
                .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .appTooltip { tooltip }
        .onPointerHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }

    // The path is the only thing that tells two projects of the same name apart, so it
    // leads the hint. The counts under it are the ones the row itself no longer carries.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: isTask ? "Runs" : "Sessions", value: "\(sessionCount)")]
        if runningCount > 0 {
            rows.append(Tooltip.Row(label: "Running", value: "\(runningCount)"))
        }
        if finishedCount > 0 {
            rows.append(Tooltip.Row(label: "Finished while away", value: "\(finishedCount)"))
        }
        if cost > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(cost)))
        }
        if let schedule = project.task?.schedule, schedule.isActive {
            rows.append(Tooltip.Row(label: "Timer", value: schedule.summary))
            if schedule.isWaitingForConfirmation {
                rows.append(Tooltip.Row(label: "Next run", value: "Waiting for confirmation"))
            } else if let nextRunAt = schedule.nextRunAt {
                rows.append(Tooltip.Row(label: "Next run",
                                        value: nextRunAt.formatted(date: .abbreviated,
                                                                   time: .shortened)))
            }
        }
        return Tooltip(title: project.name,
                       subtitle: isTask ? nil : project.collapsedPath,
                       note: isMissing ? "This folder is no longer on disk." : promptNote,
                       rows: rows)
    }

    // The saved prompt is what the Run button would send, so it belongs in the hint. One
    // line of it is enough to recognise the task by.
    private var promptNote: String? {
        guard isTask else { return nil }
        let line = (project.task?.prompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

// A hover action on the project row: the glyph with its word beside it, so what the
// button does is read rather than guessed.
private struct RowAction: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(hovering ? Theme.border : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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

// The session's folder holds work git does not have. It rides at the top of the card
// beside the state, because it is not what the session is doing: it is what deleting the
// session would cost.
private struct UncommittedMark: View {
    var body: some View {
        Image(systemName: "pencil.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.attention)
    }
}

private struct MobileConnectionMark: View {
    var body: some View {
        Image(systemName: "iphone.radiowaves.left.and.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.addition)
            .appTooltip("Phone connected")
            .accessibilityLabel("Phone connected")
    }
}

// A session as a compact card. It carries the same state, title, activity and changes the
// session shows on its project and on Home, so it reads the same wherever it is met.
private struct SessionCard: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool
    let waiting: Bool
    let needsInput: Bool
    let finished: Bool
    let activity: String?
    let added: Int
    let removed: Int
    let branch: String?
    let uncommitted: Bool
    let connected: Bool
    let isRenaming: Bool
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(AppSettings.self) private var appSettings

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var tone: SessionTone {
        SessionTone(busy: busy, needsInput: needsInput, finished: finished, waiting: waiting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StateLight(tone: tone)
                Text(tone.word)
                    .font(.mono(9, .semibold))
                    .kerning(0.9)
                    .foregroundStyle(tone.colour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if session.worktreePath != nil {
                    MonoChip(text: "WT", size: 8.5)
                }
                if uncommitted { UncommittedMark() }
                if connected { MobileConnectionMark() }
                Spacer(minLength: 4)
                // The trailing details hide in place rather than being taken out, and the
                // button that replaces them is an overlay, so the card is one size whether
                // or not the pointer is on it.
                HStack(spacing: 6) {
                    if added > 0 || removed > 0 {
                        DiffPair(added: added, removed: removed, size: 10, spacing: 4)
                    }
                    Text(RelativeTime.short(session.lastActivity))
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                }
                    .opacity(hovering ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        if hovering {
                            Button(action: onDelete) {
                                HStack(spacing: 3) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                    Text("Delete")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .appTooltip("Delete session")
                        }
                    }
            }

            HStack(spacing: 6) {
                if session.isTroubleshooting {
                    MonoChip(text: "TROUBLESHOOT", size: 8.5, tint: Theme.secret)
                }
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($focused)
                        .onSubmit { onRename(draft) }
                        .onExitCommand(perform: onCancelRename)
                } else {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .changingName(session.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ActivityLine(activity: activity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(cardStroke, lineWidth: selected ? 1.4 : 1.2))
        .animation(.easeOut(duration: 0.25), value: [busy, finished])
        .animation(.easeOut(duration: 0.15), value: selected)
        .appTooltip { tooltip }
        .onPointerHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = session.title
            focused = true
        }
    }

    // The hint carries the branch and full path because the compact card leaves both out.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: "State", value: tone.word.capitalized)]
        if let branch {
            rows.append(Tooltip.Row(label: "Branch", value: branch))
        }
        if added > 0 || removed > 0 {
            rows.append(Tooltip.Row(label: "Changes", value: "+\(added) -\(removed)"))
        }
        if appSettings.showsCost(for: session.agent),
           let usage = session.usage, usage.turns > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
        }
        if let context = session.usage?.contextFraction, context > 0 {
            rows.append(Tooltip.Row(label: "Context", value: "\(Int(context * 100))%"))
        }
        rows.append(Tooltip.Row(label: "Last active",
                                value: session.lastActivity.formatted(date: .abbreviated,
                                                                      time: .shortened)))
        return Tooltip(title: session.title,
                       subtitle: session.worktreePath?.abbreviatedPath,
                       note: note,
                       rows: rows)
    }

    // What is worth knowing before deleting this session outranks where it runs, and a
    // worktree session says both at once: the folder that would go is its own.
    private var note: String? {
        if uncommitted {
            return session.worktreePath == nil
                ? "Uncommitted changes in the project folder."
                : "Uncommitted changes in this worktree. Deleting the session loses them."
        }
        return session.worktreePath == nil ? nil : "Runs in its own git worktree."
    }

    // White is what being open looks like, so only the selected card gets it - two white
    // cards in the rail read as two open sessions. A card that is doing something says so
    // through its ring, its state light and its word, which no other card has.
    private var cardFill: Color {
        if selected { return Theme.card }
        return hovering ? Theme.field : Theme.sunken
    }

    private var cardStroke: Color {
        if selected { return Color.primary.opacity(0.3) }
        return tone == .idle ? .clear : tone.ring
    }
}

// The card at the end of a capped session list. It wears the same shape as the cards
// above it so the column stays one column, but stays quieter than any of them: it is
// a control, not a session.
private struct SeeMoreCard: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(hovering ? Color.black.opacity(0.05) : Color.black.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
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
                Text(shown)
                    .font(.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Replacements leave at once, then the current activity fades in.
                    .transition(.fadeIn)
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

// State as a word rather than a dot, so a glance down the rail reads as text. The
// old-sessions sheet borrows it for the same worktree badge the session cards wear.
struct StatusPill: View {
    let text: String
    let running: Bool
    var tint: Color? = nil
    var disclosure = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.mono(9.5, .semibold))
                .kerning(0.5)
            if disclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(fill))
    }

    private var colour: Color { tint ?? (running ? Theme.addition : Color.secondary) }

    private var fill: Color {
        tint?.opacity(0.14) ?? (running ? Theme.dotOn.opacity(0.18) : Color.black.opacity(0.05))
    }
}

private extension SessionNotice {
    var badge: String {
        switch self {
        case .needsInput: "INPUT"
        case .running: "RUNNING"
        case .finished: "FINISHED"
        }
    }

    var tint: Color {
        switch self {
        case .running: Theme.addition
        case .needsInput, .finished: Theme.attention
        }
    }
}

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}
