import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the app's tools and settings.
struct AppSidebar: View {
    let skills: SkillsManager
    let tools: ToolsMenuActions
    let onReviewOldSessions: () -> Void
    var onReviewCleanup: (CleanupHighlight) -> Void = { _ in }
    // Set while a file open in the detail pane has taken Command-F for its own find.
    let paneOwnsFindShortcut: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(OrphanedWorktreeMonitor.self) private var orphanedWorktrees
    @Environment(CleanupCoordinator.self) private var cleanup
    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(GlobalCommandPaletteController.self) private var commandPalette

    // Explicit expansion choices persist. Session navigation opens its parent again;
    // changes to the conversation itself leave those choices alone.
    @State private var expansion = Preferences.sidebarExpansion()
    @State private var collapsedGroups = Preferences.collapsedSidebarGroups()
    @State private var renamingID: UUID?
    @State private var sheet: SidebarSheet?
    // These three stay apart from `sheet` because each can be asked for while another
    // sheet is still up: creating a workspace or a task opens the next sheet as its own
    // one closes, and an import is offered once a search of the folder ends.
    @State private var newWorkspace: NewWorkspaceRequest?
    @State private var askingTask: Project?
    @State private var importingSessions: SessionImportRequest?
    @State private var sessionVisibility = SidebarSessionVisibility()
    @State private var renderedSessionIDs: Set<UUID> = []
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollOffset: CGFloat = 0
    @State private var filterBox = SidebarFilterBox()
    @State private var oldSessions = OldSessionsWatch()
    // The rows a hovered cleanup line is talking about.
    @State private var cleanupHighlight: CleanupHighlight?
    @State private var carry = SidebarCarry()
    @State var picks = SidebarMultiSelection()
    @State private var note = TransientNote()
    @FocusState private var filterFocused: Bool

    private struct SessionRevealTarget: Equatable {
        let id: UUID?
        let isRendered: Bool
    }

    private var sessionRevealTarget: SessionRevealTarget {
        SessionRevealTarget(id: store.navigation.sessionToReveal,
                            isRendered: store.navigation.sessionToReveal.map(renderedSessionIDs.contains) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
                // The work happens in another app, so a short line just above the bar is
                // the only sign in this window that the click landed.
                .overlay(alignment: .top) {
                    ZStack {
                        if let text = note.text {
                            HeaderNote(icon: note.icon, text: text)
                                .transition(.asymmetric(
                                    insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 6)))
                                        .animation(Motion.reveal),
                                    removal: .opacity.animation(Motion.leave)))
                        }
                    }
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                }
        }
        .frame(width: 318)
        .background(Theme.sidebar)
        .background(keyboardShortcuts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects and sessions")
        .onChange(of: store.sidebarDestination, initial: true) { old, destination in
            if destination?.sessionID == nil { store.navigation.sessionToReveal = nil }
            guard let destination else { return }
            setExpanded(true, for: destination.containerID)
            if let sessionID = destination.sessionID {
                filterBox.clear()
                if old?.containerID != destination.containerID {
                    store.navigation.sessionToReveal = sessionID
                } else if store.navigation.sessionToReveal == nil {
                    // Inserting a card can shift the lazy stack's estimated positions.
                    scrollPosition.scrollTo(y: scrollOffset)
                }
            }
            if old != destination { announceSelection() }
        }
        .onChange(of: filterQuery) { old, query in
            if !old.isEmpty, query.isEmpty, !filterBox.wasClearedForDisclosure() {
                revealCurrentContainer()
            }
        }
        .onChange(of: store.navigation.sessionToReveal) { _, id in
            guard let id, let session = store.sidebarSession(id) else { return }
            filterBox.clear()
            setExpanded(true, for: session.containerID)
        }
        .onChange(of: store.navigation.workspaceAddition) { _, added in
            guard let added else { return }
            store.navigation.workspaceAddition = nil
            carry.landInPlace(added, in: carrySurroundings)
        }
        .onChange(of: store.navigation.projectToReveal) { _, id in
            guard let id else { return }
            if !orderedItems.contains(where: { $0.id == id }) { filterBox.clear() }
            setExpanded(true, for: id)
        }
        .task { await watchWorkingTrees() }
        .onChange(of: cleanup.removedWorkspaces) { _, removed in
            showNote(EmptyWorkspaceSweep.removedNote(removed), icon: "hourglass")
        }
        .task(id: store.navigation.sidebarHighlight) { await endHighlight() }
        .task(id: oldSessions.rule(store: store, runner: runner, days: appSettings.oldSessionDays)) {
            await oldSessions.watch(store: store, runner: runner, days: appSettings.oldSessionDays)
        }
        .onChange(of: rowCount) { _, _ in
            picks.keep { store.project($0) != nil || store.workspace($0) != nil
                || store.sidebarSession($0) != nil }
        }
        .onChange(of: commandPalette.newSessionRequest) { _, _ in
            startSessionInSelection()
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .newSession(let project):
                    NewSessionView(project: project) { choice in
                        startSession(choice, in: project)
                    }
                case .workspaceSession(let workspace):
                    NewWorkspaceSessionView(workspace: workspace) { choice in
                        startWorkspaceSession(choice, in: workspace)
                    }
                case .cloneProject:
                    CloneProjectView(onCloned: addProjectNow)
                case .newTask:
                    NewTaskView(onCreate: createTask)
                }
            }
            .appOverlays()
        }
        // Closing the sheet either way takes the pile apart: a new workspace now stands
        // for the pair, and a cancel leaves both projects as they were.
        .sheet(item: $newWorkspace, onDismiss: carry.endPairing) { request in
            NewWorkspaceView(initialProjectIDs: request.projectIDs, initialName: request.name) { workspace in
                setExpanded(true, for: workspace.id)
                store.navigation.sidebarHighlight = workspace.id
                sheet = .workspaceSession(workspace)
            }
            .appOverlays()
        }
        .sheet(item: $importingSessions) { request in
            ImportSessionsView(request: request, onFinish: landOnProject)
                .appOverlays()
        }
        .taskRunSheet($askingTask) { task, values, note in
            startRun(task, values: values, note: note)
        }
    }

    // MARK: - Heading

    private var heading: some View {
        @Bindable var settings = appSettings
        // Both rows read the same list, so it is worked out once for the pair rather than
        // built and sorted twice on every redraw of the rail.
        let notices = sessionNotices
        let waiting = notices.filter { $0.notice != .running }
        return VStack(alignment: .leading, spacing: 0) {
            SidebarBrandBar(runningCount: notices.count { $0.notice == .running },
                            isHome: store.selection == .home,
                            selectHome: store.selectHome)
            if !waiting.isEmpty {
                SidebarNeedsYouStack(waiting: waiting, open: openNoticedSession)
                    .transition(.opacity)
            }
            SidebarFilterBar(box: $filterBox, focused: $filterFocused,
                             openCommandPalette: commandPalette.open,
                             showsShortcutHint: !paneOwnsFindShortcut)
            if picks.isActive {
                SidebarSelectionBar(count: picks.ids.count, onDone: picks.clear)
                    .transition(.fadeIn)
            } else {
                SidebarArrangementBar(sort: $settings.projectSort, grouping: $settings.projectGrouping)
                    .transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: waiting.isEmpty)
        .motion(Motion.reveal, value: picks.isActive)
    }

    private var sessionNotices: [NoticedSession] {
        SidebarNotices.all(store: store, runner: runner)
    }

    private func openNoticedSession(_ session: ChatSession) {
        let containerID = session.containerID
        filterBox.clear()
        setExpanded(true, for: containerID)
        sessionVisibility.pin(session.id, in: containerID)
        store.selectSession(session.id, destination: destination(for: session))
        store.navigation.sessionToReveal = session.id
    }

    // Where opening a card lands: the tab the session was left on. The Design
    // conversation is behind a tab rather than on a row of its own, so a card standing for
    // one opens on the board instead of the chat, which is not the conversation the card
    // was describing.
    private func destination(for session: ChatSession) -> SessionDestination {
        let last = store.lastTab(of: session.id)
        guard last == .conversation else { return last }
        return LiveConversation.of(session.id, store: store, runner: runner) == nil
            ? .conversation
            : .design
    }

    // MARK: - Projects

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current = currentItem, isFiltering,
               !orderedItems.contains(where: { $0.id == current.id }) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Current \(store.sidebarDestination?.sessionID != nil ? "session" : current.group == .workspaces ? "workspace" : "project") is outside this filter.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        filterBox.clear()
                    } label: {
                        Text("Show \(current.name) in sidebar")
                            .font(Typography.label)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.vertical, Space.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .sidebarFocusRing()
                    .appTooltip("Clear filter and reveal \(current.name)")
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.md)
            }
            if store.projects.isEmpty && store.workspaces.isEmpty {
                Text("No projects yet. Add a folder and an agent will run right inside it.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.xl)
            } else if orderedItems.isEmpty {
                Text("Nothing matches \"\(filterQuery)\".")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.xl)
            } else {
                // Grouped once per redraw, since every row below reads from this.
                let grouped = groupedSessions
                let workspaceGroups = groupedWorkspaceSessions
                ScrollViewReader { scroller in
                    ScrollView {
                        // Lazy so the rail costs what is on screen rather than what the
                        // app holds. Every card carries a hint, a menu and hover of its
                        // own, and off-screen ones would still be built and laid out on
                        // each redraw. That only holds while each card is a row of the stack itself:
                        // a card wrapped in a container is built along with all the rest.
                        LazyVStack(alignment: .leading, spacing: Self.listSpacing) {
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
                                        case .workspace(let workspace):
                                            workspaceSection(
                                                workspace,
                                                sessions: workspaceGroups[workspace.id] ?? [])
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, Space.md)
                        // Keyed on what decides whether a session block is on screen, so the
                        // transition plays wherever the change came from: a click on the
                        // project row, or the first session arriving under an open one.
                        // Easing out rather than a spring: the block must not overshoot its
                        // own height, or it opens onto a gap under the last card.
                        .motion(Motion.reveal, value: visibilityKey(grouped, workspaceGroups: workspaceGroups))
                        .motion(Motion.reveal, value: itemOrderKey)
                        .motion(Motion.reveal, value: sessionOrderKey(grouped, workspaceGroups: workspaceGroups))
                        .motion(Motion.reveal, value: appSettings.projectSort)
                        .motion(Motion.reveal, value: appSettings.projectGrouping)
                        .motion(Motion.reveal, value: collapsedGroups)
                        .motion(Motion.reveal, value: filterBox.text)
                        .motion(Motion.reveal, value: picks.isActive)
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                        scrollOffset = offset
                    }
                    .overlayPreferenceValue(SidebarCarryAnchors.self) { anchors in
                        GeometryReader { proxy in
                            SidebarCarryLayer(carried: carriedProject?.name,
                                              caption: carryCaption,
                                              flight: carry.flight,
                                              anchors: anchors,
                                              proxy: proxy,
                                              onReleased: { carry.dragReleased(in: carrySurroundings) },
                                              onLanded: { carry.flightLanded($0, in: carrySurroundings) })
                        }
                    }
                    .onPreferenceChange(SidebarRenderedSessionsKey.self) { renderedSessionIDs = $0 }
                    .onDisappear { renderedSessionIDs = [] }
                    .task(id: sessionRevealTarget) { await reveal(with: scroller) }
                    .task(id: store.navigation.projectToReveal) { await revealProject(with: scroller) }
                }
            }
        }
    }

    private static let listSpacing: CGFloat = 1

    // Under "Last used" the order is a date, so a row dragged to a new place is given a
    // date between its new neighbours. A-Z has nothing a drag could change.
    private var canReorder: Bool { appSettings.projectSort == .lastUsed }

    // A row only moves within its own section, among the rows drawn there.
    private func dropItem(_ id: UUID, beside targetID: UUID, after: Bool) {
        guard let section = sections.first(where: { $0.items.contains { $0.id == targetID } })
        else { return }
        let all = store.projects.map(SidebarItem.project)
            + store.workspaces.map(SidebarItem.workspace)
        let dates = ProjectSort.sortDates(of: all, sessions: store.sidebarSessions)
        let pinned = ProjectSort.pinnedIDs(of: all, sessions: store.sidebarSessions)
        let rows = section.items.map {
            SidebarPlacement.Row(id: $0.id, isPinned: pinned.contains($0.id), date: dates[$0.id])
        }
        guard let date = SidebarPlacement.date(moving: id, beside: targetID, after: after,
                                               in: rows) else { return }
        store.placeInSidebar(id, at: date)
    }

    private func canJoin(_ id: UUID, _ workspace: ProjectWorkspace) -> Bool {
        store.project(id)?.kind == .project && !workspace.projectIDs.contains(id)
    }

    private func holds(_ id: UUID, _ workspace: ProjectWorkspace) -> Bool {
        store.project(id)?.kind == .project && workspace.projectIDs.contains(id)
    }

    private var carrySurroundings: SidebarCarry.Surroundings {
        SidebarCarry.Surroundings(
            store: store, dialogs: dialogs, note: note, openWorkspace: openWorkspace,
            proposeWorkspace: { newWorkspace = NewWorkspaceRequest(projectIDs: $0, name: $1) })
    }

    private var carriedProject: Project? { carry.carriedProject(in: store) }

    private var carryAnchors: Bool {
        carriedProject != nil || carry.landing != nil || carry.flight != nil
    }

    private var carryCaption: SidebarCarryCaption? {
        guard carriedProject != nil, let slot = carry.drag.slot else { return nil }
        if let workspace = store.workspace(slot.targetID) {
            switch slot.place {
            case .into: return SidebarCarryCaption(kind: .add, name: workspace.name)
            case .refused: return SidebarCarryCaption(kind: .refused, name: workspace.name)
            case .before, .after: return nil
            }
        }
        guard slot.place == .into, let project = store.project(slot.targetID) else { return nil }
        return SidebarCarryCaption(kind: .pair, name: project.name)
    }

    private func roster(for workspace: ProjectWorkspace) -> SidebarRoster? {
        func members(_ ids: [UUID]) -> [SidebarRoster.Member] {
            ids.compactMap(store.project).map { SidebarRoster.Member(id: $0.id, name: $0.name) }
        }
        if let landing = carry.landing, landing.workspaceID == workspace.id {
            let project = store.project(landing.projectID)
                .map { SidebarRoster.Member(id: $0.id, name: $0.name) }
            switch landing.phase {
            case .flying:
                return SidebarRoster(workspaceID: workspace.id, members: members(landing.before.projectIDs),
                                     carried: project, aimed: true)
            case .landed:
                return SidebarRoster(workspaceID: workspace.id, members: members(workspace.projectIDs),
                                     landed: landing.projectID, landing: landing.token)
            case .leaving:
                return SidebarRoster(workspaceID: workspace.id,
                                     members: members(landing.before.projectIDs + [landing.projectID]),
                                     leaving: landing.projectID)
            }
        }
        guard let carried = carriedProject else { return nil }
        let holds = workspace.projectIDs.contains(carried.id)
        return SidebarRoster(workspaceID: workspace.id, members: members(workspace.projectIDs),
                             carried: SidebarRoster.Member(id: carried.id, name: carried.name),
                             holdsCarried: holds,
                             aimed: carry.drag.slot == SidebarDropSlot(targetID: workspace.id, place: .into))
    }

    private func canPair(_ id: UUID, with project: Project) -> Bool {
        id != project.id && store.project(id)?.kind == .project
    }

    // A session only moves among the other sessions under the same row.
    private func dropSession(_ id: UUID, beside targetID: UUID, after: Bool,
                             in sessions: [ChatSession]) {
        let rows = sessions.map {
            SidebarPlacement.Row(id: $0.id, isPinned: $0.isPinned, date: $0.sidebarDate)
        }
        guard let date = SidebarPlacement.date(moving: id, beside: targetID, after: after,
                                               in: rows) else { return }
        store.placeInSidebar(id, at: date)
    }

    private var sections: [SidebarSection] {
        appSettings.projectGrouping.sections(of: orderedItems)
    }

    // Stable identities make SwiftUI move the existing rows to their sorted positions. The
    // move is only animated when the person caused it: a pin, a drag, a row added or
    // taken away. Under "Last used" an agent at work also reorders the rows, and a list
    // gliding under the pointer while nobody touched it moves the row about to be clicked,
    // so the key leaves activity out and that reorder lands at once.
    private var itemOrderKey: [SidebarArrangement] {
        let items = sections.flatMap(\.items)
        guard appSettings.projectSort == .lastUsed else {
            return items.map { SidebarArrangement(id: $0.id) }
        }
        let pinned = ProjectSort.pinnedIDs(of: items, sessions: store.sidebarSessions)
        return items
            .map { SidebarArrangement(id: $0.id, pinned: pinned.contains($0.id), placement: $0.sidebarPlacement) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private var filter: SidebarFilter { filterBox.filter }

    private var filterQuery: String { filterBox.query }

    private var isFiltering: Bool { filterBox.isActive }

    private func matchesName(_ item: SidebarItem, _ filter: SidebarFilter) -> Bool {
        switch item {
        case .project:
            return filter.matches(name: item.name)
        case .workspace(let workspace):
            return filter.matches(name: item.name,
                                  orAnyOf: workspace.projectIDs.compactMap(store.project).map(\.name))
        }
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
        filterBox.reveal(project.id)
    }

    private func openWorkspace(_ workspace: ProjectWorkspace) {
        store.selectWorkspace(workspace.id, revealingInSidebar: false)
        setExpanded(true, for: workspace.id)
        filterBox.reveal(workspace.id)
    }

    private func toggleExpanded(_ id: UUID, expanded: Bool) {
        if isFiltering { filterBox.clearForDisclosure() }
        store.navigation.sessionToReveal = nil
        setExpanded(!expanded, for: id)
        if expanded { sessionVisibility.reset(id) }
    }

    private func revealCurrentContainer() {
        guard let destination = store.sidebarDestination else { return }
        setExpanded(true, for: destination.containerID)
        if let sessionID = destination.sessionID {
            store.navigation.sessionToReveal = sessionID
        } else {
            store.navigation.projectToReveal = destination.containerID
        }
        // Dropping the filter puts the whole rail back, which moves the current row from
        // wherever the matches had left it.
        store.navigation.sidebarHighlight = destination.sessionID ?? destination.containerID
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
                session.containerID == item.id && filter.matches(session)
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

    @ViewBuilder
    private func workspaceSection(_ workspace: ProjectWorkspace,
                                  sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(workspace)
        let visible = visibleSessions(sessions, in: workspace.id)
        let running = sessions.count { runner.isBusy($0.id) }
        let projects = workspace.projectIDs.compactMap(store.project)
        let removal = cleanup.workspaceRemoval

        WorkspaceHeaderRow(
            workspace: workspace,
            projects: projects,
            selected: store.sidebarDestination?.containerID == workspace.id,
            activeSessionTitle: activeSessionTitle(in: workspace.id),
            isExpanded: expanded && !visible.isEmpty,
            sessionCount: sessions.count,
            runningCount: running,
            needsYouCount: needsYouCount(sessions),
            isRenaming: renamingID == workspace.id,
            checked: checked(workspace.id),
            roster: roster(for: workspace),
            carryAnchors: carryAnchors,
            lifeLine: { now in
                EmptyWorkspaceSweep.lifeLine(
                    for: workspace, holdsSessions: store.holdsSessions(workspace: workspace.id),
                    removalAt: removal?.goes(workspace.id) == true ? removal?.at : nil,
                    now: now)
            },
            onKeepForGood: { keepForGood(workspace) },
            onOpen: {
                if picks.isActive { picks.click(workspace.id) } else { openWorkspace(workspace) }
            },
            onToggle: { toggleExpanded(workspace.id, expanded: expanded) },
            onNewSession: { sheet = .workspaceSession(workspace) },
            onRename: { name in
                store.renameWorkspace(workspace.id, to: name)
                renamingID = nil
            },
            onCancelRename: { renamingID = nil }
        )
        .onPressAndHold { beginSelection(with: workspace.id) }
        .appContextMenu {
            if picks.isActive { return selectionMenu(adding: workspace.id) }
            var entries: [MenuEntry] = [
                .item(workspace.isPinned ? "Unpin" : "Pin",
                      icon: workspace.isPinned ? "pin.slash" : "pin") {
                    store.setPinned(!workspace.isPinned, forWorkspace: workspace.id)
                },
                .item("Rename…") { renamingID = workspace.id },
                .item("New session") { sheet = .workspaceSession(workspace) }]
            if workspace.removeWhenEmptyAfterDays != nil {
                entries.append(.item("Keep for good", icon: "hourglass",
                                     subtitle: "Stop removing it when it sits empty.") {
                    keepForGood(workspace)
                })
            }
            entries.append(.separator)
            entries.append(.item("Delete workspace", kind: .destructive) {
                confirmRemoveWorkspace(workspace)
            })
            return entries
        }
        .sidebarRevealGlow(store.navigation.sidebarHighlight == workspace.id)
        .sidebarDrag(workspace.id,
                     reorders: canReorder,
                     drags: canReorder,
                     drag: Bindable(carry).drag,
                     takesIn: { canJoin($0, workspace) },
                     wholeRow: true,
                     holds: { holds($0, workspace) },
                     onMove: { dropItem($0, beside: workspace.id, after: $1) },
                     onDropInto: { carry.join($0, workspace, in: carrySurroundings) })
        .id(workspace.id)

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

    // The row and its cards are separate rows of the lazy list, so a long list of cards
    // is only built as far as it is on screen. The gaps around the cards belong to the
    // cards, so they leave with them and the row does not jump at the end of a close.
    @ViewBuilder
    private func projectSection(_ project: Project, sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(project)
        let visible = visibleSessions(sessions, in: project.id)
        let running = sessions.count { runner.isBusy($0.id) }

        ProjectHeaderRow(
            project: project,
            selected: store.sidebarDestination?.containerID == project.id,
            activeSessionTitle: activeSessionTitle(in: project.id),
            isExpanded: expanded && !visible.isEmpty,
            isMissing: store.isMissing(project),
            sessionCount: sessions.count,
            runningCount: running,
            unreadCount: store.unreadCount(in: project.id),
            needsYouCount: needsYouCount(sessions),
            // A project can hold sessions from either agent, so the total only counts
            // the ones whose agent is set to show what it spends.
            cost: sessions.reduce(0) { total, session in
                guard appSettings.showsCost(for: session.agent) else { return total }
                return total + (session.usage?.costUSD ?? 0)
            },
            canRunTask: running == 0,
            isRenaming: renamingID == project.id,
            checked: checked(project.id),
            carryAnchors: carryAnchors,
            stackedBehind: carry.pairing.flatMap { $0.targetID == project.id && $0.stacked
                ? store.project($0.projectID)?.name : nil },
            onOpen: {
                if picks.isActive { picks.click(project.id) } else { openProject(project) }
            },
            onToggle: { toggleExpanded(project.id, expanded: expanded) },
            onNewSession: { requestNewSession(in: project) },
            onRunTask: { runTask(project) },
            onRename: { name in
                store.renameProject(project.id, to: name)
                renamingID = nil
            },
            onCancelRename: { renamingID = nil }
        )
        .onPressAndHold { beginSelection(with: project.id) }
        .appContextMenu {
            picks.isActive ? selectionMenu(adding: project.id) : headerMenu(project)
        }
        .sidebarRevealGlow(store.navigation.sidebarHighlight == project.id)
        .sidebarDrag(project.id,
                     reorders: canReorder,
                     drags: canReorder || project.kind == .project,
                     drag: Bindable(carry).drag,
                     carriesChip: project.kind == .project,
                     takesIn: project.kind == .project ? { canPair($0, with: project) } : nil,
                     onMove: { dropItem($0, beside: project.id, after: $1) },
                     onDropInto: { carry.pair($0, with: project, in: carrySurroundings) })
        .id(project.id)

        // An expanded project with nothing under it draws no cards at all: an empty rail
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

    // The cards under an open row. A project and a workspace draw the same rail; they
    // differ only in what a card says about its branch and whether its folders hold
    // uncommitted work.
    @ViewBuilder
    private func sessionRail(_ sessions: [ChatSession], visible: [ChatSession],
                             in containerID: UUID, tint: Theme.ProjectTint,
                             branch: @escaping (ChatSession) -> String?,
                             uncommitted: @escaping (ChatSession) -> Bool) -> some View {
        // The rest of a filtered list is what did not match, so there is nothing to
        // unfold.
        let hidden = isFiltering ? 0 : sessions.count - visible.count
        ForEach(visible) { session in
            let selected = isSelected(session)
            let snooze = store.snooze(of: session.id)
            // A sleeping session is not asking for anyone, however its last turn ended.
            let finished = store.isUnread(session.id) && snooze == nil
            // Design has no card of its own, so while it is the side working, this
            // card is what says so: its light, its line and its time come from there.
            let live = LiveConversation.of(session.id, store: store, runner: runner)
                ?? session
            let state = runner.state(live.id)
            let busy = state.isBusy || runner.isAskingSecondOpinion(session.id)
            SidebarRailRow(colour: tint.colour, selectedColour: Theme.accent,
                           selected: selected, pinned: session.isPinned,
                           thread: ThreadPhase(busy: busy,
                                               failed: state.isFailed,
                                               finished: finished),
                           threadEndedCleanly: runner.lastTurnEnding(live.id)?.outcome == .finished) {
                SessionCard(session: session,
                            worktrees: store.worktreeCoverage(for: session),
                            selected: selected,
                            busy: busy,
                            failed: state.isFailed,
                            waiting: state == .waiting,
                            waitIsStale: runner.waitIsStale(live.id),
                            waitingSince: runner.waitingSince(live.id),
                            needsInput: runner.question(live.id) != nil,
                            finished: finished,
                            completionActivity: runner.rowActivity(session.id, live: live.id),
                            snoozed: snooze,
                            activity: { [runner, store] in
                                Self.activity(live, of: session.id, runner: runner, store: store)
                            },
                            branch: branch(session),
                            uncommitted: uncommitted(session),
                            connected: mobileAccess.isConnected(session: session.id),
                            isRenaming: renamingID == session.id,
                            checked: checked(session.id),
                            onOpen: {
                                if picks.isActive {
                                    picks.click(session.id)
                                    return
                                }
                                store.selectSession(session.id,
                                                    destination: destination(for: session),
                                                    revealingInSidebar: false)
                            },
                            onWake: { SessionSnoozeMenu.wake(session.id, store: store) },
                            onDelete: { confirmRemoveSession(session) },
                            onRename: { name in
                                store.renameSession(session.id, to: name)
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil })
                    .sidebarRevealGlow(store.navigation.sidebarHighlight == session.id)
                    .sidebarCleanupMark(cleanupMark(session.id))
            }
            .sidebarDrag(session.id,
                         reorders: canReorder,
                         drags: canReorder,
                         drag: Bindable(carry).drag,
                         onMove: { dropSession($0, beside: session.id, after: $1, in: sessions) })
            .id(session.id)
            .background {
                if selected {
                    GeometryReader { _ in
                        Color.clear.preference(key: SidebarRenderedSessionsKey.self,
                                               value: [session.id])
                    }
                }
            }
            .onPressAndHold { beginSelection(with: session.id) }
            .appContextMenu {
                if picks.isActive { return selectionMenu(adding: session.id) }
                return [.item(session.isPinned ? "Unpin" : "Pin",
                       icon: session.isPinned ? "pin.slash" : "pin") {
                     store.setPinned(!session.isPinned, forSession: session.id)
                 },
                 SessionUnread.menuEntry(for: session.id, store: store)]
                 + SessionSnoozeMenu.entries(for: session, store: store, dialogs: dialogs)
                 + [.item("Rename…") { renamingID = session.id },
                 SessionTitle.menuEntry(for: session.id, runner: runner, store: store),
                 .separator,
                 .item("Delete session", kind: .destructive) {
                     confirmRemoveSession(session)
                 }]
            }
            .sidebarRailSegment(colour: tint.colour,
                                isFirst: session.id == visible.first?.id,
                                isLast: hidden == 0 && session.id == visible.last?.id,
                                stackSpacing: Self.listSpacing)
            .transition(.fold)
        }
        if hidden > 0 {
            SidebarRailRow(colour: tint.colour) {
                SeeMoreCard(title: "See \(hidden) more…") {
                    sessionVisibility.showAll(containerID)
                }
            }
            .sidebarRailSegment(colour: tint.colour, isFirst: false, isLast: true,
                                stackSpacing: Self.listSpacing)
            .transition(.fold)
        }
    }

    // Read the same way the card reads its own state, so a folded row counts exactly the
    // cards that would say NEEDS YOU once it is opened.
    private func needsYouCount(_ sessions: [ChatSession]) -> Int {
        sessions.count { session in
            let live = LiveConversation.of(session.id, store: store, runner: runner) ?? session
            let state = runner.state(live.id)
            return SessionTone(busy: state.isBusy || runner.isAskingSecondOpinion(session.id),
                               needsInput: runner.question(live.id) != nil,
                               finished: store.isUnread(session.id) && !store.isSnoozed(session.id),
                               waiting: state == .waiting,
                               waitIsStale: runner.waitIsStale(live.id)) == .needsYou
        }
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
                + [.item("Reveal in Finder") { revealInFinder(project) },
                    .item("Open in \(SystemTerminal.appName)") { openInTerminal(project) },
                    .separator,
                    .item("Clear idle runs", kind: .destructive) { confirmClearSessions(in: project) },
                    .item("Delete task", kind: .destructive) { confirmRemoveProject(project) }]
        }
        return [pin,
                .item("Rename…") { renamingID = project.id },
                .item("New session") { requestNewSession(in: project) },
                .item("Import sessions…") { requestSessionImport(into: project) },
                .separator]
            + cleanup
            + [.item("Reveal in Finder") { revealInFinder(project) },
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
                               revealingAll: filterBox.revealsEverything(in: containerID),
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

    // Cards are ordered by when their sessions were last active, so this leaves activity
    // out for the same reason the rows' key does: a card that moves because its agent
    // spoke lands at once, and one the person pinned or dragged glides to its place.
    private func sessionOrderKey(_ grouped: [UUID: [ChatSession]],
                                 workspaceGroups: [UUID: [ChatSession]]) -> [[SidebarArrangement]] {
        let containers = store.workspaces.map { workspaceGroups[$0.id, default: []] }
            + store.projects.map { grouped[$0.id, default: []] }
        return containers.map { sessions in
            sessions
                .map { SidebarArrangement(id: $0.id, pinned: $0.isPinned, placement: $0.sidebarPlacement) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    // Brings the selected card on screen, and only as far as that takes: a card already
    // in view leaves the rail where the user put it. Starting a session is the common
    // case, and its card is drawn next to the row that was just clicked.
    private func reveal(with scroller: ScrollViewProxy) async {
        guard let id = store.navigation.sessionToReveal, store.sidebarDestination?.sessionID == id,
              let session = store.sidebarSession(id) else { return }
        let containerID = session.containerID
        // The card is created by the same change that asked for this, so the list has to be
        // laid out again before there is anything to scroll to.
        await Task.yield()
        guard !Task.isCancelled, expansion[containerID] != false else { return }
        guard renderedSessionIDs.contains(id) else {
            // A card far down an unfolded list is not built until it is near the screen,
            // so scrolling to its row is what builds it. The request stays until the card
            // reports itself, and the scroll that follows settles it in place.
            scroller.scrollTo(id)
            return
        }
        withAnimation(reduceMotion ? nil : Motion.reveal) {
            scroller.scrollTo(id)
        }
        store.navigation.sessionToReveal = nil
    }

    // A blink says where the rail landed once; holding the request would keep the row
    // marked long after the eye has found it.
    private func endHighlight() async {
        guard store.navigation.sidebarHighlight != nil else { return }
        try? await Task.sleep(for: .milliseconds(1_000))
        guard !Task.isCancelled else { return }
        store.navigation.sidebarHighlight = nil
    }

    // Brings a project opened away from the rail into view. The row has to be drawn
    // before it can be scrolled to, so a filter narrow enough to hide it is dropped and
    // a folded section is unfolded first.
    private func revealProject(with scroller: ScrollViewProxy) async {
        guard let id = store.navigation.projectToReveal,
              store.project(id) != nil || store.workspace(id) != nil else { return }
        if !orderedItems.contains(where: { $0.id == id }) { filterBox.clear() }
        showGroup(containing: id)
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : Motion.reveal) {
            scroller.scrollTo(id, anchor: .top)
        }
        store.navigation.projectToReveal = nil
    }

    // MARK: - Selecting several rows

    // Changes whenever a row joins or leaves the sidebar, which is when a picked row can
    // stop existing.
    private var rowCount: Int {
        store.projects.count + store.workspaces.count + store.sidebarSessions.count
    }

    // Nil outside the selection, so a row only draws its box while there is one.
    private func checked(_ id: UUID) -> Bool? {
        picks.isActive ? picks.contains(id) : nil
    }

    // A hold that ends under a dialog or on a row being renamed is aimed at that, not at
    // the row behind it.
    private func beginSelection(with id: UUID) {
        guard dialogs.current == nil, renamingID == nil else { return }
        picks.hold(id)
    }

    // A right-click on a row that is not ticked yet adds it, so the menu always acts on
    // the row it was opened from as well as the rest.
    private func selectionMenu(adding id: UUID) -> [MenuEntry] {
        picks.add(id)
        let targets = SidebarBulkAction.targets(picks.ids, in: store)
        let snooze = SidebarBulkAction.snoozeMenu(targets, in: store)
        return snooze + (snooze.isEmpty ? [] : [.separator])
            + [.item("Delete…", kind: .destructive,
                     subtitle: SidebarBulkAction.summary(of: targets)) {
                    confirmBulkDelete(targets)
                },
               .separator,
               .item("Clear selection", action: picks.clear)]
    }

    private func confirmBulkDelete(_ targets: SidebarBulkAction.Targets) {
        guard !targets.isEmpty else { return }
        dialogs.show(SidebarBulkAction.confirmation(
            for: targets, in: store, shortcuts: shortcuts, workingTrees: workingTrees) {
            picks.clear()
            Task {
                if case .failure(let failure) = await SidebarBulkAction.run(
                    targets, in: store, runner: runner, shortcuts: shortcuts) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // MARK: - Creating and removing sessions

    // Every session chooses its conversation mode up front. Git repositories also offer
    // an isolated worktree, while plain folders show only their direct folder.
    private func requestNewSession(in project: Project) {
        sheet = .newSession(project)
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        // A collapsed project keeps its new session hidden, and starting work in a project
        // is the clearest sign yet that it wants to be open.
        setExpanded(true, for: project.id)
        switch choice {
        case .worktree(let sessionID, let base, let carryChanges, let agent, let model,
                       let agentAvatarName, let mode):
            createWorktreeSession(in: project, id: sessionID, base: base,
                                  carryChanges: carryChanges, agent: agent, model: model,
                                  agentAvatarName: agentAvatarName, mode: mode)
        case .folder(let sessionID, let agent, let model, let agentAvatarName, let mode):
            switch store.insertSession(
                in: project.id,
                seed: .init(id: sessionID, agent: agent, model: model,
                            agentAvatarName: agentAvatarName, mode: mode)) {
            case .success(let session):
                store.navigation.sessionToReveal = session.id
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
                choice, in: workspace, store: store, composer: runner.composer) {
            case .success:
                store.navigation.sessionToReveal = choice.sessionID
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
    // included. The worktrees get their own row: they are the part of this that touches
    // disk, and the part that can take uncommitted work with it.
    private func confirmClearSessions(in project: Project) {
        let idle = idleSessions(in: project)
        guard !idle.isEmpty else { return }
        let worktrees = idle.flatMap { store.checkoutProjects(for: $0).compactMap(\.worktreePath) }
        let dirty = worktrees.count(where: workingTrees.isDirty)
        let designs = idle.count { store.hasDesignArtifacts(for: $0) }
        let kept = store.standaloneSessions(for: project.id).count - idle.count

        var rows = [Dialog.Impact.Row(title: counted(idle.count, "session"),
                                      detail: "Conversation history is removed from Code Station.")]
        if !worktrees.isEmpty {
            rows.append(.init(
                title: counted(worktrees.count, "worktree"),
                detail: "Removed from disk."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits.")))
        }
        if designs > 0 {
            rows.append(.init(title: "Generated Design files",
                              detail: "Permanently removed from \(counted(designs, "session"))."))
        }
        if kept > 0 {
            rows.append(.init(title: "\(counted(kept, "running session")) \(kept == 1 ? "stays" : "stay")",
                              detail: "Sessions that are still working are left alone.", kept: true))
        }
        rows.append(.init(title: "Original project folder stays", detail: project.collapsedPath, kept: true))

        dialogs.show(.impact("Clear \(counted(idle.count, "session")) from \(project.name)?",
                             message: "Sessions that are not running will leave Code Station.",
                             subject: .init(name: project.name), rows: rows,
                             warning: dirty > 0
                                 ? "Uncommitted changes and conversation history cannot be restored."
                                 : "Conversation history cannot be restored.",
                             action: "Clear sessions") {
            Task {
                if case .failure(let failure) = await SessionRemoval.run(
                    idle, in: store, runner: runner) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    private func idleSessions(in project: Project) -> [ChatSession] {
        store.standaloneSessions(for: project.id).filter { !runner.isBusy($0.id) }
    }

    private func confirmRemoveProject(_ project: Project) {
        ProjectRemoval.confirm(project, in: store, runner: runner, shortcuts: shortcuts,
                               dialogs: dialogs)
    }

    private func keepForGood(_ workspace: ProjectWorkspace) {
        store.keepForGood(workspace: workspace.id)
        showNote("\(workspace.name) will stay until you delete it", icon: "checkmark")
    }

    private func confirmRemoveWorkspace(_ workspace: ProjectWorkspace) {
        WorkspaceRemoval.confirm(workspace, in: store, runner: runner, dialogs: dialogs)
    }

    // The session id is chosen up front so the worktree folder and branch can carry
    // it before the session exists, which is also what lets the sheet name both.
    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       carryChanges: Bool, agent: AgentKind, model: String?,
                                       agentAvatarName: String?, mode: SessionMode) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agent: agent, model: model,
                agentAvatarName: agentAvatarName, mode: mode, carryChanges: carryChanges,
                store: store, composer: runner.composer) {
            case .success:
                store.navigation.sessionToReveal = sessionID
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
    private static func activity(_ session: ChatSession, of rowID: UUID, runner: SessionRunner,
                                 store: ProjectStore) -> String? {
        if let activity = runner.rowActivity(rowID, live: session.id) { return activity.label }
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
        VStack(alignment: .leading, spacing: Space.md) {
            if appSettings.oldSessionsDeleteOnTheirOwn {
                CleanupStrip(status: cleanup.status, onReview: onReviewCleanup) { highlight in
                    cleanupHighlight = highlight
                }
            } else if oldSessions.summary.sessions > 0 {
                OldSessionsOfferStrip(summary: oldSessions.summary,
                                      days: appSettings.oldSessionDays,
                                      onReview: onReviewOldSessions)
                    .transition(.fold)
            }
            if let removal = cleanup.workspaceRemoval {
                EmptyWorkspacesStrip(removal: removal) { id in
                    if let workspace = store.workspace(id) { openWorkspace(workspace) }
                }
                .transition(.fold)
            }
            if showsOrphanedWorktreesStrip { OrphanedWorktreesStrip() }

            HStack(spacing: Space.md) {
                ActionButton(title: "Add", height: ControlHeight.xl, size: Typography.Size.body, fills: true)
                    .appMenu(edge: .top, matchWidth: true, addMenu)
                    .accessibilityLabel("Add a project, workspace, or task")

                SettingsButton(showsUpdate: skills.updateCount > 0
                               || appUpdates.availableRelease != nil)
                    .toolsMenu(tools, skills: skills, edge: .top)
            }

            if !runner.catalog.available {
                Text("\(runner.catalog.agent.title) was not found on PATH.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.lg)
        .motion(Motion.reveal, value: cleanup.status.parked.isEmpty)
        .motion(Motion.reveal, value: cleanup.status.deletion == nil)
        .motion(Motion.reveal, value: oldSessions.summary.sessions > 0)
        .motion(Motion.reveal, value: cleanup.workspaceRemoval == nil)
        .onChange(of: appSettings.oldSessionsDeleteOnTheirOwn) { _, _ in cleanupHighlight = nil }
    }

    // When cleanup looks after orphans they are counted in its card. Otherwise this is
    // the only place they are named.
    private var showsOrphanedWorktreesStrip: Bool {
        let rule = appSettings.cleanupRule
        return !orphanedWorktrees.worktrees.isEmpty
            && !(rule.deletesOnItsOwn && rule.includesOrphans)
    }

    private func cleanupMark(_ sessionID: UUID) -> SidebarCleanupMark.Tone? {
        switch cleanupHighlight {
        case .goes: cleanup.status.goes(sessionID) ? .goes : nil
        case .waits: cleanup.status.waits(sessionID) ? .waits : nil
        case nil: nil
        }
    }

    // MARK: - Actions

    private func addMenu() -> [MenuEntry] {
        return [
            .item("Add project", icon: "folder.badge.plus",
                  subtitle: "Choose an existing folder.", action: addProject),
            .item("Clone repository", icon: "arrow.down.circle",
                  subtitle: "Copy one from a Git URL.") {
                sheet = .cloneProject
            },
            .item("Create workspace", icon: "square.stack.3d.up.fill",
                  subtitle: "Group two or more projects.") {
                newWorkspace = NewWorkspaceRequest(projectIDs: [])
            },
            .item("New task", icon: "bolt.fill",
                  subtitle: "A saved prompt you can run any time.") {
                sheet = .newTask
            }
        ]
    }

    // The shortcuts the whole window answers. They live on the sidebar because everything
    // they reach - the filter field, the first item waiting on a person, the project a new
    // session would start in - is here.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { startSessionInSelection() }
                .appShortcut(.newSession)
            Button("") {
                commandPalette.close()
                filterBox.openField()
                Task {
                    await Task.yield()
                    filterFocused = true
                }
            }
                .appShortcut(.filterSidebar)
            Button("") { jumpToFirstNeedingAttention() }
                .appShortcut(.nextWaiting)
            if picks.isActive {
                Button("") { picks.clear() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
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
            sheet = .workspaceSession(workspace)
        case nil:
            // Nothing is selected, so there is no folder to start in yet.
            addProject()
        }
    }

    private func addProject() {
        guard let url = FilePicker.chooseFolder(
            prompt: "Add Project",
            message: "Pick the folder the agents should work in.") else { return }

        // Sessions the agents already ran in the folder are offered before the project is
        // added, so they can come along with it. A folder that is already a project only
        // offers the ones the app does not hold yet.
        let existing = store.projects.first {
            ClaudeSessionCatalog.standardized($0.path) == ClaudeSessionCatalog.standardized(url.path)
        }
        Task {
            let request = await SessionImportRequest.load(folder: url.path, projectID: existing?.id,
                                                         store: store)
            if request.candidates.isEmpty {
                addProjectNow(at: url)
            } else {
                if let existing { landOnProject(existing.id) }
                importingSessions = request
            }
        }
    }

    private func addProjectNow(at url: URL) {
        // A folder that is already a project comes back as nil, and the store has
        // pointed itself at the existing one. Either way the rail lands on that project:
        // the list is ordered by the sort setting, so a project can be added anywhere
        // in it, including off screen.
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        landOnProject(id)
    }

    private func landOnProject(_ id: UUID) {
        setExpanded(true, for: id)
        filterBox.clear()
        store.selectProject(id, revealingInSidebar: true)
    }

    // Opened from the project's menu, the sheet always comes up, even with nothing found:
    // that is where it says where it looked and offers to look somewhere else.
    private func requestSessionImport(into project: Project) {
        Task {
            importingSessions = await SessionImportRequest.load(folder: project.path,
                                                             projectID: project.id, store: store)
        }
    }

    // Creating a task lands on its screen rather than in a session: the task is the
    // thing that was made, and running it is its own click - unless it was asked for.
    private func createTask(_ draft: NewTaskDraft) {
        switch store.addTask(named: draft.name, prompt: draft.prompt) {
        case .success(let project):
            if var spec = project.task {
                spec.agent = draft.agent
                spec.agentAvatarName = draft.agentAvatarName
                if var schedule = draft.schedule {
                    schedule.restart()
                    spec.schedule = schedule
                }
                store.setTaskSpec(spec, for: project.id)
            }
            setExpanded(true, for: project.id)
            filterBox.clear()
            store.selectProject(project.id, revealingInSidebar: true)
            if draft.runNow { runTask(store.project(project.id) ?? project) }
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
            store.navigation.sessionToReveal = session.id
        case .failure(let failure):
            dialogs.show(.notice("Could not run the task", message: failure.message))
        }
    }

    private func openInTerminal(_ project: Project) {
        SystemTerminal.open(project.url)
        showNote("Opened \(project.name) in \(SystemTerminal.appName)", icon: "terminal")
    }

    private func revealInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
        showNote("Showed \(project.name) in Finder", icon: "folder")
    }

    // MARK: - Notes

    private func showNote(_ text: String, icon: String) {
        note.show(text, icon: icon)
    }
}

// MARK: - Parts

private struct SidebarRenderedSessionsKey: PreferenceKey {
    static let defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}

private struct SidebarFocusRing: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .sidebarFocusRing($focused)
    }
}

extension View {
    func sidebarFocusRing() -> some View { modifier(SidebarFocusRing()) }

    func sidebarFocusRing(_ focused: FocusState<Bool>.Binding) -> some View {
        self.focused(focused)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: focused.wrappedValue))
    }
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
            .surface(hovering ? Theme.field : Theme.card, cornerRadius: Radius.card)
            .overlay(alignment: .topTrailing) {
                if showsUpdate { UpdateIndicator().offset(x: 3, y: -3) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
            .hoverLift(hovering, amount: Motion.smallLift)
            .appTooltip("Tools and settings")
            .onPointerHover { hovering = $0 }
            .accessibilityLabel("Tools and settings")
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
            HStack(spacing: Space.sm) {
                Text(title.uppercased())
                    .font(Typography.caps)
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                if collapsed {
                    Text("\(count)")
                        .font(Typography.caps)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 8)
                    .opacity(hovering || collapsed ? 1 : 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .sidebarFocusRing()
        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(title)")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .appTooltip(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }
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
        // Reduce Motion asks for no flicker, so the mark stays up longer instead of not
        // being drawn at all.
        withAnimation(Motion.reveal) { glow = 1 }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 900 : 420))
        withAnimation(Motion.leave) { glow = 0 }
    }
}

// The wash a row wears while a cleanup line that names it is under the pointer: red
// for what the countdown will take, amber for what waits for a yes.
private struct SidebarCleanupMark: ViewModifier {
    enum Tone {
        case goes
        case waits
    }

    let tone: Tone?

    private var colour: Color {
        switch tone {
        case .goes: Theme.deletion
        case .waits: Theme.attention
        case nil: .clear
        }
    }

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.card)
                .fill(colour.opacity(tone == nil ? 0 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(colour.opacity(tone == nil ? 0 : 0.5), lineWidth: 1)
                .allowsHitTesting(false))
            .motion(Motion.hover, value: tone)
    }
}

private extension View {
    func sidebarRevealGlow(_ revealed: Bool) -> some View {
        modifier(SidebarRevealGlow(revealed: revealed))
    }

    func sidebarCleanupMark(_ tone: SidebarCleanupMark.Tone?) -> some View {
        modifier(SidebarCleanupMark(tone: tone))
    }
}

// The sheets a click in the sidebar opens. Only ever one at a time.
private enum SidebarSheet: Identifiable {
    case newSession(Project)
    case workspaceSession(ProjectWorkspace)
    case cloneProject
    case newTask

    var id: String {
        switch self {
        case .newSession(let project): "session-\(project.id)"
        case .workspaceSession(let workspace): "workspace-session-\(workspace.id)"
        case .cloneProject: "clone"
        case .newTask: "task"
        }
    }
}

private struct NewWorkspaceRequest: Identifiable {
    let id = UUID()
    let projectIDs: [UUID]
    var name = ""
}

// What decides a row's or a card's place in the rail that the person set themselves.
struct SidebarArrangement: Equatable {
    let id: UUID
    var pinned = false
    var placement: SidebarPlacement?
}
