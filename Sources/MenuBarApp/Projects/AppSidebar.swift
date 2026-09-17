import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the app's tools and settings.
struct AppSidebar: View {
    let skills: SkillsManager
    let tools: ToolsMenuActions
    let oldSessionDeletion: OldSessionSweep.Deletion?
    let onReviewOldSessions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(OrphanedWorktreeMonitor.self) private var orphanedWorktrees
    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(GlobalCommandPaletteController.self) private var commandPalette

    // Explicit expansion choices persist. Session navigation opens its parent again;
    // changes to the conversation itself leave those choices alone.
    @State private var expansion = Preferences.sidebarExpansion()
    @State private var collapsedGroups = Preferences.collapsedSidebarGroups()
    @State private var renamingID: UUID?
    @State private var choosingSessionKind: Project?
    @State private var choosingWorkspaceSession: ProjectWorkspace?
    @State private var showingNewWorkspace = false
    @State private var showingNewTask = false
    @State private var askingTask: Project?
    @State private var sessionVisibility = SidebarSessionVisibility()
    @State private var renderedSessionIDs: Set<UUID> = []
    @State private var filterText = ""
    @State private var sidebarFilterOpen = false
    @State private var revealedFilterContainerID: UUID?
    @State private var clearedFilterForDisclosure = false
    @State private var oldSessionSummary = OldSessionSummary()
    @State private var hoveringOldSessions = false
    @State private var hoveringOrphanedWorktrees = false
    @State private var hoveringHome = false
    @FocusState private var filterFocused: Bool

    private static let oldSessionRefreshInterval: TimeInterval = 3_600

    private struct SessionRevealTarget: Equatable {
        let id: UUID?
        let isRendered: Bool
    }

    private var sessionRevealTarget: SessionRevealTarget {
        SessionRevealTarget(id: store.sessionToReveal,
                            isRendered: store.sessionToReveal.map(renderedSessionIDs.contains) ?? false)
    }

    private struct OldSessionSummary: Equatable {
        var sessions = 0
        var losesWork = 0
        // Projects whose snooze is holding old sessions back. A snooze over a project
        // with nothing old to hide is not worth a line in the strip.
        var snoozedProjects = 0
    }

    private struct OldSessionRefreshRule: Equatable {
        struct Session: Equatable {
            let id: UUID
            let isBusy: Bool
            let isPinned: Bool
        }

        let days: Int
        let oldSessions: [Session]
        let nextOldAt: Date?
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects and sessions")
        .onChange(of: store.sidebarDestination, initial: true) { old, destination in
            if destination?.sessionID == nil { store.sessionToReveal = nil }
            guard let destination else { return }
            setExpanded(true, for: destination.containerID)
            if let sessionID = destination.sessionID {
                filterText = ""
                store.sessionToReveal = sessionID
            }
            if old != destination { announceSelection() }
        }
        .onChange(of: filterQuery) { old, query in
            if !old.isEmpty, query.isEmpty {
                if !clearedFilterForDisclosure { revealCurrentContainer() }
                clearedFilterForDisclosure = false
            }
        }
        .onChange(of: store.sessionToReveal) { _, id in
            guard let id, let session = store.sidebarSession(id) else { return }
            filterText = ""
            setExpanded(true, for: containerID(of: session))
        }
        .onChange(of: store.projectToReveal) { _, id in
            guard let id else { return }
            if !orderedItems.contains(where: { $0.id == id }) { filterText = "" }
            setExpanded(true, for: id)
        }
        .task { await watchWorkingTrees() }
        .task(id: store.sidebarHighlight) { await endHighlight() }
        .task(id: oldSessionRefreshRule) { await refreshOldSessionsHourly() }
        .onChange(of: commandPalette.newSessionRequest) { _, _ in
            startSessionInSelection()
        }
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

    // The visible control opens the app-wide filter. Command-F keeps the narrower tree
    // filter for someone who only wants to trim this rail without leaving its context.
    private var filterBar: some View {
        Group {
            if sidebarFilterOpen || !filterText.isEmpty {
                sidebarFilterField
            } else {
                Button { commandPalette.open() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Filter projects, sessions, actions")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("⌘K")
                            .font(.mono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .fieldSurface(cornerRadius: 9)
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter projects, sessions, and actions")
                .appTooltip("Filter Code Station (command-K)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var sidebarFilterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects and sessions", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($filterFocused)
            Text("⌘F")
                .font(.mono(9.5))
                .foregroundStyle(.tertiary)
            Button {
                if filterText.isEmpty {
                    sidebarFilterOpen = false
                    filterFocused = false
                } else {
                    filterText = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip(filterText.isEmpty ? "Close project filter" : "Clear filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fieldSurface(cornerRadius: 9)
        .onChange(of: filterText) { _, _ in revealedFilterContainerID = nil }
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
            let live = LiveConversation.id(of: session.id, store: store, runner: runner)
            let question = runner.question(live)
            guard let notice = SessionNotice(
                isBusy: runner.state(live).isBusy,
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
            return activity(session) ?? "running"
        case .finished:
            return "finished while away"
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
        store.selectSession(session.id, destination: destination(for: session))
        store.sessionToReveal = session.id
    }

    // Where opening a card lands. The Design conversation is behind a tab rather than on
    // a row of its own, so a card standing for one has to open on the board: the chat it
    // would otherwise show is not the conversation the card was describing.
    private func destination(for session: ChatSession) -> SessionDestination {
        LiveConversation.of(session.id, store: store, runner: runner) == nil
            ? .conversation
            : .design
    }

    // MARK: - Projects

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current = currentItem, isFiltering,
               !orderedItems.contains(where: { $0.id == current.id }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current \(store.sidebarDestination?.sessionID != nil ? "session" : current.group == .workspaces ? "workspace" : "project") is outside this filter.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button {
                        filterText = ""
                    } label: {
                        Text("Show \(current.name) in sidebar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sidebarFocusRing()
                    .appTooltip("Clear filter and reveal \(current.name)")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
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
                                                   collapsed: isCollapsed(section)) {
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
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.26),
                                   value: visibilityKey(grouped, workspaceGroups: workspaceGroups))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: itemOrderKey)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22),
                                   value: sessionOrderKey(grouped,
                                                          workspaceGroups: workspaceGroups))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: appSettings.projectSort)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: appSettings.projectGrouping)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: collapsedGroups)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: filterText)
                    }
                    .onPreferenceChange(SidebarRenderedSessionsKey.self) { renderedSessionIDs = $0 }
                    .onDisappear { renderedSessionIDs = [] }
                    .task(id: sessionRevealTarget) { await reveal(with: scroller) }
                    .task(id: store.projectToReveal) { await revealProject(with: scroller) }
                }
            }
        }
    }

    private var sections: [SidebarSection] {
        appSettings.projectGrouping.sections(of: orderedItems)
    }

    // Stable identities make SwiftUI move the existing rows to their sorted positions.
    // The order itself must be the animation value because pinning changes neither sort
    // preference, and pinning a session may leave the order inside its container unchanged.
    private var itemOrderKey: [UUID] {
        sections.flatMap(\.items).map(\.id)
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

    private var currentItem: SidebarItem? {
        guard let id = store.sidebarDestination?.containerID else { return nil }
        return store.workspace(id).map(SidebarItem.workspace)
            ?? store.project(id).map(SidebarItem.project)
    }

    private func activeSessionTitle(in containerID: UUID) -> String? {
        guard let destination = store.sidebarDestination,
              destination.containerID == containerID,
              let id = destination.sessionID else { return nil }
        return store.sidebarSession(id)?.title
    }

    private func openProject(_ project: Project) {
        store.selectProject(project.id, revealingInSidebar: false)
        setExpanded(true, for: project.id)
        if isFiltering { revealedFilterContainerID = project.id }
    }

    private func openWorkspace(_ workspace: ProjectWorkspace) {
        store.selectWorkspace(workspace.id, revealingInSidebar: false)
        setExpanded(true, for: workspace.id)
        if isFiltering { revealedFilterContainerID = workspace.id }
    }

    private func toggleExpanded(_ id: UUID, expanded: Bool) {
        if isFiltering {
            clearedFilterForDisclosure = true
            filterText = ""
        }
        store.sessionToReveal = nil
        setExpanded(!expanded, for: id)
        if expanded { sessionVisibility.reset(id) }
    }

    private func revealCurrentContainer() {
        guard let destination = store.sidebarDestination else { return }
        setExpanded(true, for: destination.containerID)
        if let sessionID = destination.sessionID {
            store.sessionToReveal = sessionID
        } else {
            store.projectToReveal = destination.containerID
        }
        // Dropping the filter puts the whole rail back, which moves the current row from
        // wherever the matches had left it.
        store.sidebarHighlight = destination.sessionID ?? destination.containerID
    }

    private func announceSelection() {
        guard let current = currentItem, let window = NSApp.keyWindow else { return }
        let message = if let title = activeSessionTitle(in: current.id) {
            "Viewing \(title) in \(current.name)."
        } else {
            "\(current.name), current \(current.group == .workspaces ? "workspace" : "project")."
        }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.low.rawValue])
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
        for key in groups.keys {
            groups[key]?.sort(by: SessionSort.pinnedFirstByLastActivity)
        }
        return groups
    }

    private var groupedWorkspaceSessions: [UUID: [ChatSession]] {
        let groups = Dictionary(grouping: store.sidebarSessions.compactMap { session in
            session.workspaceID.map { ($0, session) }
        }, by: \.0)
        return groups.mapValues { rows in
            rows.map(\.1).sorted(by: SessionSort.pinnedFirstByLastActivity)
        }
    }

    private func workspaceSection(_ workspace: ProjectWorkspace,
                                  sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(workspace)
        let visible = visibleSessions(sessions, in: workspace.id)
        let running = sessions.count { runner.isBusy($0.id, store: store) }
        let projects = workspace.projectIDs.compactMap(store.project)

        return VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeaderRow(
                workspace: workspace,
                projects: projects,
                selected: store.sidebarDestination?.containerID == workspace.id,
                activeSessionTitle: activeSessionTitle(in: workspace.id),
                isExpanded: expanded && !visible.isEmpty,
                sessionCount: sessions.count,
                runningCount: running,
                finishedCount: store.finishedCount(inWorkspace: workspace.id),
                isRenaming: renamingID == workspace.id,
                onOpen: { openWorkspace(workspace) },
                onToggle: { toggleExpanded(workspace.id, expanded: expanded) },
                onNewSession: { choosingWorkspaceSession = workspace },
                onRename: { name in
                    store.renameWorkspace(workspace.id, to: name)
                    renamingID = nil
                },
                onCancelRename: { renamingID = nil }
            )
            .appContextMenu {
                [.item(workspace.isPinned ? "Unpin" : "Pin",
                       icon: workspace.isPinned ? "pin.slash" : "pin") {
                     store.setPinned(!workspace.isPinned, forWorkspace: workspace.id)
                 },
                 .item("Rename…") { renamingID = workspace.id },
                 .item("New session") { choosingWorkspaceSession = workspace },
                 .separator,
                 .item("Delete workspace", kind: .destructive) {
                     confirmRemoveWorkspace(workspace)
                 }]
            }
            .sidebarRevealGlow(store.sidebarHighlight == workspace.id)

            if expanded, !visible.isEmpty {
                sessionRail(sessions, visible: visible, in: workspace.id,
                            tint: sidebarRailTint(for: workspace.sidebarAvatar,
                                                  name: workspace.name,
                                                  monogramTint: Theme.workspaceTint),
                            branch: workspaceBranch,
                            uncommitted: { session in
                                store.workingDirectories(for: session).contains(where: workingTrees.isDirty)
                            })
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
        let running = sessions.count { runner.isBusy($0.id, store: store) }

        // The row and its sessions are one stack so the gap between them belongs to the
        // block that changes size. An outer spacing would remain after the block leaves,
        // which reads as the row jumping at the end of the close.
        return VStack(alignment: .leading, spacing: 0) {
            ProjectHeaderRow(
                project: project,
                selected: store.sidebarDestination?.containerID == project.id,
                activeSessionTitle: activeSessionTitle(in: project.id),
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
                canRunTask: running == 0,
                isRenaming: renamingID == project.id,
                onOpen: { openProject(project) },
                onToggle: { toggleExpanded(project.id, expanded: expanded) },
                onNewSession: { requestNewSession(in: project) },
                onRunTask: { runTask(project) },
                onRename: { name in
                    store.renameProject(project.id, to: name)
                    renamingID = nil
                },
                onCancelRename: { renamingID = nil }
            )
            .appContextMenu { headerMenu(project) }
            .sidebarRevealGlow(store.sidebarHighlight == project.id)

            // An expanded project with nothing under it draws no block at all: an empty one
            // still carries its padding, which reads as the row shifting on every click.
            if expanded, !visible.isEmpty {
                sessionRail(sessions, visible: visible, in: project.id,
                            tint: sidebarRailTint(for: project.sidebarAvatar,
                                                  name: project.name,
                                                  monogramTint: Theme.projectTint(for: project.name)),
                            branch: { branch($0, project: project) },
                            uncommitted: { workingTrees.isDirty(folder($0, project: project)) })
            }
        }
    }

    // The cards under an open row. A project and a workspace draw the same rail; they
    // differ only in what a card says about its branch and whether its folders hold
    // uncommitted work.
    private func sessionRail(_ sessions: [ChatSession], visible: [ChatSession],
                             in containerID: UUID, tint: Theme.ProjectTint,
                             branch: @escaping (ChatSession) -> String?,
                             uncommitted: @escaping (ChatSession) -> Bool) -> some View {
        SidebarRail(colour: tint.colour) {
            ForEach(visible) { session in
                let selected = isSelected(session)
                // Design has no card of its own, so while it is the side working, this
                // card is what says so: its light, its line and its time come from there.
                let live = LiveConversation.of(session.id, store: store, runner: runner)
                    ?? session
                SidebarRailRow(colour: tint.colour, selectedColour: Theme.accent, selected: selected) {
                    SessionCard(session: session,
                                worktrees: store.worktreeCoverage(for: session),
                                selected: selected,
                                busy: runner.state(live.id).isBusy,
                                waiting: runner.state(live.id) == .waiting,
                                waitIsStale: runner.waitIsStale(live.id),
                                waitingSince: runner.waitingSince(live.id),
                                needsInput: runner.question(live.id) != nil,
                                finished: store.hasFinished(session.id),
                                activity: activity(live),
                                branch: branch(session),
                                uncommitted: uncommitted(session),
                                connected: mobileAccess.isConnected(session: session.id),
                                isRenaming: renamingID == session.id,
                                onOpen: {
                                    store.selectSession(session.id,
                                                        destination: destination(for: session),
                                                        revealingInSidebar: false)
                                },
                                onDelete: { confirmRemoveSession(session) },
                                onRename: { name in
                                    store.renameSession(session.id, to: name)
                                    renamingID = nil
                                },
                                onCancelRename: { renamingID = nil })
                        .sidebarRevealGlow(store.sidebarHighlight == session.id)
                }
                .id(session.id)
                .background {
                    if selected {
                        GeometryReader { _ in
                            Color.clear.preference(key: SidebarRenderedSessionsKey.self,
                                                   value: [session.id])
                        }
                    }
                }
                .appContextMenu {
                    [.item(session.isPinned ? "Unpin" : "Pin",
                           icon: session.isPinned ? "pin.slash" : "pin") {
                         store.setPinned(!session.isPinned, forSession: session.id)
                     },
                     .item("Rename…") { renamingID = session.id },
                     SessionTitle.menuEntry(for: session.id, runner: runner, store: store),
                     .separator,
                     .item("Delete session", kind: .destructive) {
                         confirmRemoveSession(session)
                     }]
                }
            }
            // The rest of a filtered list is what did not match, so there is nothing to
            // unfold.
            let hidden = isFiltering ? 0 : sessions.count - visible.count
            if hidden > 0 {
                SidebarRailRow(colour: tint.colour) {
                    SeeMoreCard(title: "See \(hidden) more…") {
                        sessionVisibility.showAll(containerID)
                    }
                }
            }
        }
        .transition(.fadeIn)
    }

    private func sidebarRailTint(for avatar: SidebarAvatar, name: String,
                                 monogramTint: Theme.ProjectTint) -> Theme.ProjectTint {
        avatar.identityTint(
            iconSet: appSettings.sidebarIconSet,
            style: appSettings.diceBearAvatarStyle,
            name: name,
            monogramTint: monogramTint)
    }

    // Tasks and projects share the row but not its menu: a task is run rather than
    // started, and deleting it takes its app-owned folder along.
    private func headerMenu(_ project: Project) -> [MenuEntry] {
        let pin = MenuEntry.item(project.isPinned ? "Unpin" : "Pin",
                                 icon: project.isPinned ? "pin.slash" : "pin") {
            store.setPinned(!project.isPinned, forProject: project.id)
        }
        let snoozed = ProjectSnooze.isActive(project.snoozedUntil)
        var cleanup: [MenuEntry] = [
            .item(snoozed ? "Snooze cleanup 1 more day" : "Snooze cleanup 1 day",
                  icon: "clock") {
                store.snoozeCleanup(forProject: project.id)
            }]
        if snoozed {
            cleanup.append(.item("Wake now", icon: "clock.badge.xmark") {
                store.wakeCleanup(forProject: project.id)
            })
        }
        if project.kind == .adHoc {
            return [pin,
                    .item("Run task") { runTask(project) },
                    .item("Rename…") { renamingID = project.id },
                    .separator]
                + cleanup
                + [.item("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    },
                    .item("Open in \(SystemTerminal.appName)") { openInTerminal(project) },
                    .separator,
                    .item("Clear idle runs", kind: .destructive) { confirmClearSessions(in: project) },
                    .item("Delete task", kind: .destructive) { confirmRemoveProject(project) }]
        }
        return [pin,
                .item("Rename…") { renamingID = project.id },
                .item("New session") { requestNewSession(in: project) },
                .separator]
            + cleanup
            + [.item("Reveal in Finder") {
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
        return expansion[project.id] ?? (project.id == store.sidebarDestination?.containerID)
    }

    private func isExpanded(_ workspace: ProjectWorkspace) -> Bool {
        isFiltering || (expansion[workspace.id] ?? true)
    }

    private func setExpanded(_ isExpanded: Bool, for id: UUID) {
        expansion[id] = isExpanded
        Preferences.setSidebarExpansion(expansion)
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
        Preferences.setCollapsedSidebarGroups(collapsedGroups)
    }

    private func showGroup(containing id: UUID) {
        let item = store.project(id).map(SidebarItem.project)
            ?? store.workspace(id).map(SidebarItem.workspace)
        guard let group = item?.group, collapsedGroups.remove(group) != nil else { return }
        Preferences.setCollapsedSidebarGroups(collapsedGroups)
    }

    // A list stays capped at its chosen number of sessions unless the user unfolded it with
    // see-more, so a new session pushes the last visible one below the fold. A filtered
    // list starts with just its matches, then shows the complete container after its row is
    // clicked so the result can be explored without clearing the filter.
    private func visibleSessions(_ sessions: [ChatSession], in containerID: UUID) -> [ChatSession] {
        let filter = self.filter
        let destination = store.sidebarDestination
        let selectedSessionID = destination?.containerID == containerID ? destination?.sessionID : nil
        guard filter.isActive else {
            return sessionVisibility.visible(
                sessions, in: containerID, limit: appSettings.sidebarSessionLimit,
                selectedSessionID: selectedSessionID)
        }
        return filter.sessions(from: sessions,
                               revealingAll: revealedFilterContainerID == containerID,
                               selectedSessionID: selectedSessionID)
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

    // Brings the selected card on screen, and only as far as that takes: a card already
    // in view leaves the rail where the user put it. Starting a session is the common
    // case, and its card is drawn next to the row that was just clicked.
    private func reveal(with scroller: ScrollViewProxy) async {
        guard let id = store.sessionToReveal, store.sidebarDestination?.sessionID == id,
              let session = store.sidebarSession(id) else { return }
        let containerID = containerID(of: session)
        // The card is created by the same change that asked for this, so the list has to be
        // laid out again before there is anything to scroll to.
        await Task.yield()
        guard !Task.isCancelled, expansion[containerID] != false else { return }
        guard renderedSessionIDs.contains(id) else {
            // Lazy rows report their cards after layout. Keep the request until that
            // happens, or a scroll can stop at a parent whose card does not exist yet.
            scroller.scrollTo(containerID)
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) {
            scroller.scrollTo(id)
        }
        store.sessionToReveal = nil
    }

    // A blink says where the rail landed once; holding the request would keep the row
    // marked long after the eye has found it.
    private func endHighlight() async {
        guard store.sidebarHighlight != nil else { return }
        try? await Task.sleep(for: .milliseconds(1_000))
        guard !Task.isCancelled else { return }
        store.sidebarHighlight = nil
    }

    // Brings a project opened away from the rail into view. The row has to be drawn
    // before it can be scrolled to, so a filter narrow enough to hide it is dropped and
    // a folded section is unfolded first.
    private func revealProject(with scroller: ScrollViewProxy) async {
        guard let id = store.projectToReveal,
              store.project(id) != nil || store.workspace(id) != nil else { return }
        if !orderedItems.contains(where: { $0.id == id }) { filterText = "" }
        showGroup(containing: id)
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) {
            scroller.scrollTo(id, anchor: .top)
        }
        store.projectToReveal = nil
    }

    // MARK: - Creating and removing sessions

    // Every session chooses its conversation mode up front. Git repositories also offer
    // an isolated worktree, while plain folders show only their direct folder.
    private func requestNewSession(in project: Project) {
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        // A collapsed project keeps its new session hidden, and starting work in a project
        // is the clearest sign yet that it wants to be open.
        setExpanded(true, for: project.id)
        switch choice {
        case .worktree(let sessionID, let base, let agent, let model, let agentAvatarName,
                       let mode):
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent,
                                  model: model, agentAvatarName: agentAvatarName, mode: mode)
        case .folder(let sessionID, let agent, let model, let agentAvatarName, let mode):
            switch store.insertSession(
                in: project.id,
                seed: .init(id: sessionID, agent: agent, model: model,
                            agentAvatarName: agentAvatarName, mode: mode)) {
            case .success(let session):
                store.sessionToReveal = session.id
            case .failure(let failure):
                dialogs.show(.notice("Could not create the session", message: failure.message))
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
                store.sessionToReveal = choice.sessionID
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }

    private func confirmRemoveSession(_ session: ChatSession) {
        SessionRemoval.confirm(session, in: store, runner: runner,
                               workingTrees: workingTrees, dialogs: dialogs)
    }

    // Clearing a project keeps whatever is still running and takes the rest, worktrees
    // included. The message counts the worktrees separately: they are the part of this
    // that touches disk, and the part that can take uncommitted work with it.
    private func confirmClearSessions(in project: Project) {
        let idle = idleSessions(in: project)
        guard !idle.isEmpty else { return }
        let worktreePaths = idle.map { store.checkoutProjects(for: $0).compactMap(\.worktreePath) }
        let worktrees = worktreePaths.count { !$0.isEmpty }
        let dirty = worktreePaths.count { $0.contains(where: workingTrees.isDirty) }
        let designs = idle.count { store.hasDesignArtifacts(for: $0) }
        let kept = store.standaloneSessions(for: project.id).count - idle.count
        var message = "Their conversation history is removed from the app."
        if designs > 0 {
            message += designs == 1
                ? " One session contains generated Design files that are permanently removed."
                : " \(designs) sessions contain generated Design files that are permanently removed."
        }
        if worktrees > 0 {
            message += " \(worktrees) of them ran in a worktree. Uncommitted changes there are lost, and branches are kept only where they have unmerged commits."
        }
        if dirty > 0 {
            message += " \(dirty) of those worktree\(dirty == 1 ? " has" : "s have") uncommitted changes right now."
        }
        if kept > 0 {
            message += " The \(kept) still running stay\(kept == 1 ? "s" : "")."
        }
        dialogs.show(.confirm("Clear \(counted(idle.count, "session")) from \(project.name)?",
                              message: message, action: "Clear sessions") {
            Task {
                if case .failure(let failure) = await SessionRemoval.run(
                    idle, in: store, runner: runner) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    private func idleSessions(in project: Project) -> [ChatSession] {
        store.standaloneSessions(for: project.id).filter { !runner.isBusy($0.id, store: store) }
    }

    private func confirmRemoveProject(_ project: Project) {
        ProjectRemoval.confirm(project, in: store, runner: runner, shortcuts: shortcuts,
                               dialogs: dialogs)
    }

    private func confirmRemoveWorkspace(_ workspace: ProjectWorkspace) {
        WorkspaceRemoval.confirm(workspace, in: store, runner: runner, dialogs: dialogs)
    }

    // The session id is chosen up front so the worktree folder and branch can carry
    // it before the session exists, which is also what lets the sheet name both.
    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       agent: AgentKind, model: String?, agentAvatarName: String?,
                                       mode: SessionMode) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agent: agent, model: model,
                agentAvatarName: agentAvatarName, mode: mode, store: store) {
            case .success:
                store.sessionToReveal = sessionID
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }

    // The line under a session's title. A running session shows the call in flight
    // ("Bash · swift build"), which the runner keeps while the turn is alive. Everything
    // else reads from the saved summary, so the rail never observes transcript writes.
    // A pending permission is left out: a session waiting on one is already on the
    // needs-you card above.
    private func activity(_ session: ChatSession) -> String? {
        let runningTool = runner.state(session.id).isBusy ? runner.runningTool(session.id) : nil
        let tasks = runner.backgroundTasks(session.id)
        // A card with nothing to say draws no line, where a wider row would say so in words.
        guard runningTool != nil || !tasks.isEmpty || session.summary.lastTool != nil else {
            return nil
        }
        return SessionActivity.line(permission: nil, runningTool: runningTool,
                                    root: store.workingDirectory(for: session) ?? "",
                                    lastTool: session.summary.lastTool,
                                    finished: store.hasFinished(session.id),
                                    backgroundTasks: tasks)
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
            if !orphanedWorktrees.worktrees.isEmpty { orphanedWorktreesStrip }

            HStack(spacing: 8) {
                ActionButton(title: "Add", height: 38, size: 13, fills: true)
                    .appMenu(edge: .top, matchWidth: true, addMenu)
                    .accessibilityLabel("Add a project, workspace, or task")

                SettingsButton(showsUpdate: skills.updateCount > 0
                               || appUpdates.availableRelease != nil)
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
    // each one would cost. Once the sweep has a cohort waiting, the strip switches to
    // that cohort: the count beside the countdown is what the sweep will take, so the
    // number a person reads before walking away is the number that goes.
    private func oldSessionsStrip(_ summary: OldSessionSummary) -> some View {
        let losesWork = summary.losesWork > 0
        return Button(action: onReviewOldSessions) {
            ZStack {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.stripTitle(summary, deleting: oldSessionDeletion?.sessions,
                                             days: oldSessionDays))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(losesWork ? Theme.attentionText : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(Self.stripDetail(summary, deleting: oldSessionDeletion?.sessions,
                                              days: oldSessionDays))
                            .font(.mono(10))
                            .foregroundStyle(losesWork ? Theme.attentionText : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let deletionAt = oldSessionDeletion?.at {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let countdownIsUrgent = CleanupCountdown.isUrgent(
                                until: deletionAt,
                                now: context.date)
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(CleanupCountdown.text(
                                    until: deletionAt,
                                    now: context.date))
                                    .font(.mono(10, .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(countdownIsUrgent
                                ? Theme.deletion
                                : losesWork ? Theme.attentionText : Theme.accent)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Automatic deletion countdown")
                            .accessibilityValue(CleanupCountdown.text(
                                until: deletionAt,
                                now: context.date))
                        }
                    }
                }
                .opacity(hoveringOldSessions ? 0 : 1)

                Text("Click to review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(losesWork ? Theme.attentionText : Color.primary)
                    .opacity(hoveringOldSessions ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .surface(losesWork ? Theme.attention.opacity(0.10) : Theme.field, cornerRadius: 9,
                     border: losesWork ? Theme.attention.opacity(0.45) : .clear)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveringOldSessions)
        .onHover { hoveringOldSessions = $0 }
        .accessibilityLabel("Review old sessions")
    }

    // The strip makes one statement at a time. Once a cohort is waiting the top line is a
    // promise about that cohort and nothing else, so it counts the sessions the sweep has
    // already settled on rather than everything that has gone quiet.
    private static func stripTitle(_ summary: OldSessionSummary, deleting: Int?,
                                   days: Int) -> String {
        guard let deleting else {
            return "\(counted(summary.sessions, "session")) older than \(counted(days, "day"))"
        }
        return "\(counted(deleting, "session")) will be deleted"
    }

    // Under a promise the detail carries the threshold the top line gave up naming and
    // says what the cohort is leaving behind. With no cohort waiting the strip is only an
    // offer to review, so the detail counts what accepting it would cost.
    private static func stripDetail(_ summary: OldSessionSummary, deleting: Int?,
                                    days: Int) -> String {
        guard let deleting else { return reviewDetail(summary) }
        var parts = ["Older than \(counted(days, "day"))"]
        // The summary is refreshed on its own slower clock, so it can lag a cohort that
        // has just lost a member.
        let kept = max(0, summary.sessions - deleting)
        if kept > 0 { parts.append("\(kept) kept for review") }
        if summary.snoozedProjects > 0 {
            parts.append("\(counted(summary.snoozedProjects, "project")) snoozed")
        }
        return parts.joined(separator: " · ")
    }

    // "1 project snoozed · 1 would lose work", so a quiet strip is never a mystery.
    // With nothing snoozed the line says only what it has always said.
    private static func reviewDetail(_ summary: OldSessionSummary) -> String {
        let work = summary.losesWork == 1
            ? "1 session would lose work"
            : "\(summary.losesWork) sessions would lose work"
        guard summary.snoozedProjects > 0 else { return work }
        let snoozed = "\(counted(summary.snoozedProjects, "project")) snoozed"
        guard summary.losesWork > 0 else { return snoozed }
        return "\(snoozed) · \(summary.losesWork) would lose work"
    }

    private var oldSessionDays: Int { appSettings.oldSessionDays }

    private var oldSessionRefreshRule: OldSessionRefreshRule {
        let sessions = store.sidebarSessions
        return OldSessionRefreshRule(
            days: oldSessionDays,
            oldSessions: OldSessions.olderThan(oldSessionDays, in: sessions,
                                               snoozedUntil: snoozeDeadline).map {
                OldSessionRefreshRule.Session(
                    id: $0.id,
                    isBusy: runner.isBusy($0.id, store: store),
                    isPinned: $0.isPinned)
            },
            nextOldAt: OldSessions.nextOldAt(oldSessionDays, in: sessions,
                                             snoozedUntil: snoozeDeadline))
    }

    private func refreshOldSessions() async {
        let old = OldSessions.olderThan(oldSessionDays, in: store.sidebarSessions)
            .filter { !runner.isBusy($0.id, store: store) }
        let heldBack = old.filter { ProjectSnooze.isActive(snoozeDeadline($0)) }
        let sessions = old.filter { !ProjectSnooze.isActive(snoozeDeadline($0)) }
        var losesWork = 0
        for session in sessions {
            guard !Task.isCancelled else { return }
            let cost = await SessionCost.settledCost(
                worktrees: store.checkoutProjects(for: session).compactMap(\.worktreePath),
                deletesDesignArtifacts: store.hasDesignArtifacts(for: session))
            if cost.losesWork { losesWork += 1 }
        }
        guard !Task.isCancelled else { return }
        oldSessionSummary = OldSessionSummary(sessions: sessions.count,
                                              losesWork: losesWork,
                                              snoozedProjects: Set(heldBack.map(\.projectID)).count)
    }

    private func snoozeDeadline(_ session: ChatSession) -> Date? {
        store.snoozeDeadline(for: session)
    }

    private func refreshOldSessionsHourly() async {
        while !Task.isCancelled {
            await refreshOldSessions()
            let now = Date()
            let hourlyRefresh = now.addingTimeInterval(
                Self.oldSessionRefreshInterval)
            // The earliest snooze deadline counts as well, so the strip wakes up on the
            // minute a project comes back rather than at the next hourly pass.
            let nextOldSession = OldSessions.nextOldAt(
                oldSessionDays, in: store.sidebarSessions, now: now,
                snoozedUntil: snoozeDeadline)
            let nextRefresh = min(hourlyRefresh, nextOldSession ?? .distantFuture)
            do {
                try await Task.sleep(for: .seconds(max(0, nextRefresh.timeIntervalSinceNow)))
            } catch {
                return
            }
        }
    }

    private var orphanedWorktreesStrip: some View {
        let worktrees = orphanedWorktrees.worktrees
        let count = worktrees.count
        let bytes = worktrees.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let size = bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : "No disk usage"

        return Button { confirmPruneOrphanedWorktrees(worktrees) } label: {
            ZStack {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(counted(count, "orphaned worktree"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.attentionText)
                            .lineLimit(1)
                        Text("No session · \(size)")
                            .font(.mono(10))
                            .foregroundStyle(Theme.attentionText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if appSettings.autoPruneOrphanedWorktrees,
                       let deletionAt = orphanedWorktrees.automaticDeletionAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let countdownIsUrgent = CleanupCountdown.isUrgent(
                                until: deletionAt,
                                now: context.date)
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(CleanupCountdown.text(until: deletionAt,
                                                           now: context.date))
                                    .font(.mono(10, .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(countdownIsUrgent
                                ? Theme.deletion
                                : Theme.attentionText)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Automatic pruning countdown")
                            .accessibilityValue(CleanupCountdown.text(
                                until: deletionAt,
                                now: context.date))
                        }
                    }
                }
                .opacity(hoveringOrphanedWorktrees ? 0 : 1)

                Text("Click to prune")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.attentionText)
                    .opacity(hoveringOrphanedWorktrees ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .surface(Theme.attention.opacity(0.10), cornerRadius: 9,
                     border: Theme.attention.opacity(0.45))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(orphanedWorktrees.isPruning)
        .opacity(orphanedWorktrees.isPruning ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveringOrphanedWorktrees)
        .onHover { hoveringOrphanedWorktrees = $0 }
        .accessibilityLabel("Prune orphaned worktrees")
    }

    private func confirmPruneOrphanedWorktrees(_ worktrees: [OrphanedWorktree]) {
        guard !worktrees.isEmpty else { return }
        dialogs.show(OrphanedWorktreePruning.confirmation(for: worktrees) {
            Task { await pruneOrphanedWorktrees(worktrees) }
        })
    }

    private func pruneOrphanedWorktrees(_ worktrees: [OrphanedWorktree]) async {
        let result = await orphanedWorktrees.prune(worktrees, in: store)
        guard !result.failures.isEmpty else { return }
        dialogs.show(.notice("Could not prune some worktrees",
                             message: result.failures.map(\.message).joined(separator: "\n")))
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
            Button("") {
                commandPalette.close()
                sidebarFilterOpen = true
                Task {
                    await Task.yield()
                    filterFocused = true
                }
            }
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
        guard let url = FilePicker.chooseFolder(
            prompt: "Add Project",
            message: "Pick the folder Claude Code should work in.") else { return }

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
            dialogs.show(.notice("Could not create the task", message: failure.message))
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
            store.sessionToReveal = session.id
        case .failure(let failure):
            dialogs.show(.notice("Could not run the task", message: failure.message))
        }
    }

    private func openInTerminal(_ project: Project) {
        SystemTerminal.open(project.url)
    }
}

// MARK: - Rows

private struct SidebarRenderedSessionsKey: PreferenceKey {
    static let defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}

private struct SidebarDisclosure: View {
    let name: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarFocusRing()
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(name) sessions")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .appTooltip("\(expanded ? "Collapse" : "Expand") \(name) sessions")
    }
}

private struct SidebarFocusRing: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Theme.accent : .clear, lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false))
    }
}

private extension View {
    func sidebarFocusRing() -> some View { modifier(SidebarFocusRing()) }
}

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
            .surface(hovering ? Theme.field : Theme.card, cornerRadius: 9)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .sidebarFocusRing()
        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(title)")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .appTooltip(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }
}

// One line per workspace. The stacked tile distinguishes it from a single project without
// introducing another icon language into the sidebar.
private struct WorkspaceHeaderRow: View {
    let workspace: ProjectWorkspace
    let projects: [Project]
    let selected: Bool
    let activeSessionTitle: String?
    let isExpanded: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let isRenaming: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            if isRenaming {
                SidebarIdentityTile(
                    avatar: workspace.sidebarAvatar,
                    name: workspace.name,
                    tint: Theme.workspaceTint,
                    stacked: true)
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(4)
                    .fieldSurface(cornerRadius: 5)
                    .font(.system(size: 13.5, weight: .semibold))
                    .focused($focused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: 9) {
                        SidebarIdentityTile(
                            avatar: workspace.sidebarAvatar,
                            name: workspace.name,
                            tint: Theme.workspaceTint,
                            stacked: true)
                        HStack(spacing: 5) {
                            Text(workspace.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            if workspace.isPinned { PinnedMark() }
                            if finishedCount > 0 { FinishedDot() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarFocusRing()
                .accessibilityLabel("Open \(workspace.name)")
                .accessibilityValue(selected
                    ? "Current workspace" + (!isExpanded ? activeSessionTitle.map { ". Viewing \($0)" } ?? "" : "")
                    : "")
                .accessibilityAddTraits(selected && activeSessionTitle == nil ? [.isSelected] : [])

                // The count belongs to the row whether or not it is the current one:
                // the sidebar is read at a glance, and a row that drops its number
                // reads as a row with nothing in it. The slot keeps its width so the
                // chevrons stay in one column down the list.
                if sessionCount > 0 || runningCount > 0 || hovering {
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 6) {
                            if runningCount > 0 { RunningDot() }
                            if sessionCount > 0 {
                                Text(counted(sessionCount, "session"))
                                    .font(.mono(10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(hovering ? 0 : 1)

                        if hovering {
                            RowAction(icon: "plus", title: "New", action: onNewSession)
                                .fixedSize()
                                .appTooltip("New multi-project session")
                        }
                    }
                    .frame(minWidth: 62, alignment: .trailing)
                }
                if sessionCount > 0 {
                    SidebarDisclosure(name: workspace.name, expanded: isExpanded, action: onToggle)
                }
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

// The current container keeps its navigation marker even when its sessions are folded.
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
                .stroke(selected ? Theme.accent.opacity(0.14) : .clear, lineWidth: 1))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .accessibilityHidden(true)
                }
            }
    }

    private var fill: Color {
        if selected { return Theme.accent.opacity(0.085) }
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
    let activeSessionTitle: String?
    let isExpanded: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let cost: Double
    let canRunTask: Bool
    let isRenaming: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRunTask: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var isTask: Bool { project.kind == .adHoc }

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            if isRenaming {
                SidebarIdentityTile(
                    avatar: project.sidebarAvatar,
                    name: project.name,
                    tint: Theme.projectTint(for: project.name),
                    dashed: project.kind == .adHoc)
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(4)
                    .fieldSurface(cornerRadius: 5)
                    .font(.system(size: 13.5, weight: .semibold))
                    .focused($focused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: 9) {
                        SidebarIdentityTile(
                            avatar: project.sidebarAvatar,
                            name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            dashed: project.kind == .adHoc)
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
                            if project.isPinned { PinnedMark() }
                            // The only mark a snoozed project carries. Its tooltip gives
                            // the day its sessions come back into the cleanup list.
                            if let snoozedUntil = project.snoozedUntil,
                               ProjectSnooze.isActive(snoozedUntil) {
                                MonoChip(text: ProjectSnooze.badge(until: snoozedUntil), size: 9.5)
                                    .appTooltip("Cleanup snoozed until \(ProjectSnooze.wakeDay(snoozedUntil))")
                            }
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarFocusRing()
                .accessibilityLabel("Open \(project.name)")
                .accessibilityValue(selected
                    ? "Current project" + (!isExpanded ? activeSessionTitle.map { ". Viewing \($0)" } ?? "" : "")
                    : "")
                .accessibilityAddTraits(selected && activeSessionTitle == nil ? [.isSelected] : [])

                // The running light gives way under the pointer to the things you come to
                // a project row to do. The name gives way while the pointer is here for
                // those actions, so the wider labels do not make the row grow.
                if !selected || hovering || runningCount > 0 {
                    ZStack(alignment: .trailing) {
                        if runningCount > 0 {
                            RunningDot()
                                .opacity(hovering ? 0 : 1)
                        }

                        if hovering {
                            // A task is run with its saved prompt rather than opened
                            // empty. The button waits while a run is still working in
                            // the task's folder.
                            Group {
                                if isTask {
                                    if canRunTask {
                                        RowAction(icon: "play.fill", title: "Run", compact: selected, action: onRunTask)
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
                    .frame(minWidth: selected ? 0 : 30, alignment: .trailing)
                }
                if sessionCount > 0 {
                    SidebarDisclosure(name: project.name, expanded: isExpanded, action: onToggle)
                }
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
        let line = (project.task?.prompt ?? "").trimmed
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

// A hover action on the project row: the glyph with its word beside it, so what the
// button does is read rather than guessed.
private struct RowAction: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: String
    let title: String
    var compact = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 4 : 7)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(hovering ? Theme.border : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .sidebarFocusRing()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
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

struct PinnedMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .appTooltip("Pinned")
            .accessibilityLabel("Pinned")
    }
}

// A session as a compact card. It carries the same state, title and activity the session
// shows on its project and on Home, so it reads the same wherever it is met.
private struct SessionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    let worktrees: WorktreeCoverage
    let selected: Bool
    let busy: Bool
    let waiting: Bool
    let waitIsStale: Bool
    // When the turn stopped working, which is what a wait has to be counted from. The
    // session's own last activity is the start of the turn still holding it, so on a long
    // turn it reads as a far longer wait than the one actually being served.
    let waitingSince: Date?
    let needsInput: Bool
    let finished: Bool
    let activity: String?
    let branch: String?
    let uncommitted: Bool
    let connected: Bool
    let isRenaming: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(AppSettings.self) private var appSettings

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var tone: SessionTone {
        SessionTone(busy: busy, needsInput: needsInput, finished: finished,
                    waiting: waiting, waitIsStale: waitIsStale)
    }

    var body: some View {
        Group {
            if isRenaming {
                cardContent
            } else {
                Button(action: onOpen) { cardContent }
                    .buttonStyle(.plain)
                    .sidebarFocusRing()
                    .accessibilityLabel(session.title)
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering, !isRenaming {
                Button(action: onDelete) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Delete")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarFocusRing()
                .accessibilityLabel("Delete session")
                .appTooltip("Delete session")
                .padding(.top, selected ? 6 : 5)
                .padding(.trailing, 7)
            }
        }
        .appTooltip { tooltip }
        .onPointerHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = session.title
            focused = true
        }
    }

    private var accessibilityStatus: String {
        var labels = [tone.word.capitalized]
        if selected { labels.append("Currently viewing") }
        if session.isPinned { labels.append("Pinned") }
        if uncommitted { labels.append("Uncommitted changes") }
        if connected { labels.append("Phone connected") }
        if worktrees.isComplete { labels.append("In a worktree") }
        if worktrees.isPartial { labels.append("Partly in a worktree") }
        return labels.joined(separator: ", ")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StateLight(tone: tone)
                Text(tone.word)
                    .font(.mono(9, .semibold))
                    .kerning(0.9)
                    .foregroundStyle(tone.colour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if session.isPinned { PinnedMark() }
                // WT means every checkout is a worktree. A session that is only partly
                // in worktrees still shares a folder, so it wears MIXED in the amber of
                // something that needs a look. The tooltip names which projects share.
                if worktrees.isComplete {
                    MonoChip(text: "WT", size: 8.5)
                } else if worktrees.isPartial {
                    MonoChip(text: "MIXED", size: 8.5, tint: Theme.attentionText)
                }
                if uncommitted { UncommittedMark() }
                if connected { MobileConnectionMark() }
                Spacer(minLength: 4)
                Text(RelativeTime.short(waiting ? waitingSince ?? session.lastActivity
                                                : session.lastActivity))
                    .font(.mono(9.5))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
            }

            HStack(spacing: 6) {
                if session.isTroubleshooting {
                    MonoChip(text: "TROUBLESHOOT", size: 8.5, tint: Theme.secret)
                }
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .padding(4)
                        .fieldSurface(cornerRadius: 5)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($focused)
                        .onSubmit { onRename(draft) }
                        .onExitCommand(perform: onCancelRename)
                } else {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(selected ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                        .changingName(session.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ActivityLine(activity: activity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, selected ? 9 : 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(cardStroke, lineWidth: selected ? 1.4 : 1.2))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: [busy, finished])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    // The hint carries the branch and full path because the compact card leaves both out.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: "State", value: tone.word.capitalized)]
        if let branch {
            rows.append(Tooltip.Row(label: "Branch", value: branch))
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
    // worktree session says both at once: the folder that would go is its own. A session
    // that is only partly in worktrees names the projects it still shares, since the
    // chip has no room for them.
    private var note: String? {
        if uncommitted {
            return session.worktreePath == nil
                ? "Uncommitted changes in the project folder."
                : "Uncommitted changes in this worktree. Deleting the session loses them."
        }
        if worktrees.isPartial {
            return "Runs in a worktree for \(worktrees.isolated.formatted(.list(type: .and))). Shares the project folder of \(worktrees.shared.formatted(.list(type: .and)))."
        }
        return worktrees.isComplete ? "Runs in its own git worktree." : nil
    }

    // White is what being open looks like, so only the selected card gets it - two white
    // cards in the rail read as two open sessions. A card that is doing something says so
    // through its ring, its state light and its word, which no other card has.
    private var cardFill: Color {
        if selected { return Theme.card }
        return hovering ? Theme.field : Theme.sunken
    }

    private var cardStroke: Color {
        if selected { return Theme.accent.opacity(0.64) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: shown)
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

// The rail's way of saying where it landed. A row opened from somewhere else - the
// command palette, Home, a link in a conversation - is scrolled into view and then blinks
// green once, which is enough to find it in a long list without moving anything.
private struct SidebarRevealGlow: ViewModifier {
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow: Double = 0

    // Every row in the rail is drawn on this radius, so the glow sits on the edge the row
    // already has rather than around it.
    private static let radius: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Self.radius)
                .fill(Theme.addition.opacity(glow * 0.16)))
            .overlay(RoundedRectangle(cornerRadius: Self.radius)
                .stroke(Theme.addition.opacity(glow), lineWidth: 1.5)
                .shadow(color: Theme.addition.opacity(glow * 0.75), radius: 6)
                .allowsHitTesting(false))
            .task(id: revealed) { await blink() }
    }

    private func blink() async {
        guard revealed else { return }
        // Reduce Motion asks for no flicker, so the mark arrives and leaves more slowly
        // instead of not being drawn at all.
        withAnimation(.easeOut(duration: reduceMotion ? 0.3 : 0.16)) { glow = 1 }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 700 : 320))
        withAnimation(.easeIn(duration: reduceMotion ? 0.4 : 0.3)) { glow = 0 }
    }
}

private extension View {
    func sidebarRevealGlow(_ revealed: Bool) -> some View {
        modifier(SidebarRevealGlow(revealed: revealed))
    }
}
