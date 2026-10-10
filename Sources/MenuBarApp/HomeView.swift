import SwiftUI

// Where the app opens, so it answers the three questions you have on landing: what
// happened, what needs me, and what do I go back to. It is a status screen rather than a
// pitch - the case for the app is only made once, on the empty state, when there is no
// status to report yet.
struct HomeView: View {
    let onReviewOldSessions: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(SessionTimeWatch.self) private var sessionTimes

    // Recomputed once per redraw and handed down, because every section below counts over
    // the same list of sessions.
    private struct Standing {
        var sessions: [HomeLive] = []
        var resumable: [HomeLive] = []
        var addedToday = 0
        var removedToday = 0
        var sessionsToday = 0
        var sessionsChangedToday = 0
        // Held as paths rather than counted per session, since every session checked out
        // into the same worktree is looking at the one directory.
        var worktrees: Set<String> = []
        var worktreeSessions = 0
        // Every session the time breakdown could have something to draw for, and the
        // scans that back them.
        var timeline: [RibbonSession] = []
        var timeRequests: [SessionTimeWatch.Request] = []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.projects.isEmpty && store.workspaces.isEmpty {
                HomeIntroduction()
            } else {
                let standing = standing
                status(standing)
            }
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.brand)
                .frame(width: 8, height: 8)
            Text("Home")
                .font(.serif(17, .semibold))
            SectionLabel(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .uppercased()
                         + " · " + Date().formatted(date: .omitted, time: .shortened),
                         style: .field)

            Spacer(minLength: 12)

            if appSettings.mobileAccessEnabled {
                MobileAccessButton(scope: .everything)
            }
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    // MARK: - Status

    private func status(_ standing: Standing) -> some View {
        let map = HomeWorkMap(sessions: standing.sessions)
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction(map)
                    HomeWorkMapView(map: map,
                                    compact: geometry.size.width - 48 < 650) { live in
                        open(live)
                    }
                    timeSpent(standing)
                    dailyTotals(standing)
                    resume(standing)
                    if !oldSessions.isEmpty { cleanup() }
                }
                .animation(HomeWorkMapView.reflow, value: map.shape)
                .padding(24)
            }
        }
    }

    private func introduction(_ map: HomeWorkMap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your work, in motion.").font(.serif(36, .medium))
            Text("\(counted(map.runningCount, "session")) working. "
                 + (map.waiting.isEmpty ? "You're all caught up." : "\(map.waiting.count) need your attention."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func open(_ live: HomeLive) {
        let destination = live.primaryAction(hasChanges: hasChanges(in: live.session)).destination
        store.selectSession(live.id, destination: destination)
    }

    private func dailyTotals(_ standing: Standing) -> some View {
        FlowRow(spacing: 22) {
            HStack(spacing: 8) {
                if scanned(standing) {
                    DiffPair(added: standing.addedToday, removed: standing.removedToday, size: 14)
                } else {
                    Text("Counting…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("lines changed today").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .appTooltip(changedNote(standing))
            Text("\(counted(standing.sessionsToday, "session")) today")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text("\(counted(standing.worktrees.count, "worktree"))")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .appTooltip("Across \(counted(standing.worktreeSessions, "session"))")
        }
    }

    // What today's turns wrote, rather than everything the sessions that ran today have
    // ever written. Until the scans behind it land the day is not measured, and a card
    // saying nothing changed would be claiming an answer it does not have yet.
    private func changedNote(_ standing: Standing) -> String {
        guard standing.sessionsToday > 0 else { return "No sessions have run today" }
        guard scanned(standing) else { return "Adding up today's changes" }
        guard standing.sessionsChangedToday > 0 else { return "No files were changed" }
        return "across \(counted(standing.sessionsChangedToday, "session"))"
    }

    // Whether every session the day covers has been read off disk yet.
    private func scanned(_ standing: Standing) -> Bool {
        standing.timeRequests.allSatisfy { sessionTimes.hasScanned($0.id) }
    }

    // MARK: - Where the day went

    private func timeSpent(_ standing: Standing) -> some View {
        DayRibbonSection(
            ribbon: DayRibbon.build(standing.timeline,
                                    spans: sessionTimes.spans(for:),
                                    now: Date()),
            scanned: scanned(standing),
            onOpen: { id in
                if let live = standing.sessions.first(where: { $0.id == id }) { open(live) }
            })
            .task(id: standing.timeRequests) {
                sessionTimes.refresh(standing.timeRequests)
            }
    }

    private func hasChanges(in session: ChatSession) -> Bool {
        let roots = store.workingDirectories(for: session)
        guard roots.allSatisfy(workingTrees.hasInspected) else {
            return session.summary.added > 0 || session.summary.removed > 0
        }
        return roots.contains(where: workingTrees.isDirty)
    }

    private func resume(_ standing: Standing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Still on your mind?").font(.serif(20))
                Spacer()
                ActionButton(title: "All \(standing.sessions.count) sessions", tone: .outlined,
                             height: 28, size: 11.5, disclosure: true)
                    .appMenu {
                        [.searchable(standing.sessions.map { live in
                            MenuItem(label: live.session.title, projectTint: live.tint,
                                     badge: live.status, subtitle: live.containerName,
                                     handler: { open(live) })
                        }, prompt: "Find a session", noResults: "No sessions match your search.")]
                    }
            }
            if !standing.resumable.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(standing.resumable.prefix(6)) { live in
                        ResumeCard(live: live) { open(live) }
                    }
                }
            } else {
                Text("Recent conversations will appear here when you're ready to return to them.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func cleanup() -> some View {
        let stale = oldSessions
        let worktrees = Set(stale.flatMap {
            store.checkoutProjects(for: $0).compactMap(\.worktreePath)
        })
        return FooterStrip(
            title: "\(counted(stale.count, "session")) older than \(appSettings.oldSessionDays) days",
            detail: worktrees.isEmpty
                ? "nothing left checked out"
                : "\(counted(worktrees.count, "worktree")) still checked out") {
            InlineLink(title: "Clean up →", size: 12.5, action: onReviewOldSessions)
        }
    }

    // MARK: - Reading the store

    private var oldSessions: [ChatSession] {
        OldSessions.olderThan(appSettings.oldSessionDays, in: store.sidebarSessions)
            .filter { !runner.isBusy($0.id, store: store) }
    }

    // A session whose last message falls outside the band can still hold a turn whose
    // calls reported in after it, so the net is cast a little wider than the band itself.
    private static let timelineGrace: TimeInterval = 6 * 3_600

    private var standing: Standing {
        var standing = Standing()
        let calendar = Calendar.current
        let timelineStart = DayRibbon.axis(endingAt: Date()).start
            .addingTimeInterval(-Self.timelineGrace)

        for session in store.sidebarSessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            // A Design conversation has no row of its own, so while it is the side
            // working, the session that opened it is what Home has to describe.
            let live = LiveConversation.of(session.id, store: store, runner: runner) ?? session
            let busy = runner.state(live.id).isBusy
            let permission = runner.question(live.id)
            let finished = store.isUnread(session.id)
            let identity = identity(of: session)
            let card = describe(session, identity: identity, live: live, busy: busy,
                                permission: permission, finished: finished)

            if session.lastActivity > timelineStart || busy {
                // A session and the Design conversation working beside it are one piece
                // of work, so their turns land on one block rather than two.
                let sources = live.id == session.id ? [session.id] : [session.id, live.id]
                let projectPath = store.workingDirectory(for: session) ?? ""
                standing.timeline.append(
                    RibbonSession(id: session.id,
                                  title: session.title,
                                  subject: RibbonSubject(name: identity.name,
                                                         tint: identity.tint),
                                  sources: sources,
                                  isOpen: busy))
                standing.timeRequests.append(
                    SessionTimeWatch.Request(id: session.id, mark: session.summary,
                                             isRunning: busy && live.id == session.id,
                                             projectPath: projectPath))
                if live.id != session.id {
                    standing.timeRequests.append(
                        SessionTimeWatch.Request(id: live.id, mark: live.summary,
                                                 isRunning: busy, projectPath: projectPath))
                }

                let today = sources.flatMap(sessionTimes.changes(for:))
                    .filter { calendar.isDateInToday($0.date) }
                if !today.isEmpty {
                    standing.addedToday += today.reduce(0) { $0 + $1.added }
                    standing.removedToday += today.reduce(0) { $0 + $1.removed }
                    standing.sessionsChangedToday += 1
                }
            }

            standing.sessions.append(card)
            if card.tone == .idle, session.hasStarted || live.hasStarted {
                standing.resumable.append(card)
            }

            if calendar.isDateInToday(session.lastActivity) { standing.sessionsToday += 1 }

            let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
            standing.worktrees.formUnion(worktrees)
            if !worktrees.isEmpty { standing.worktreeSessions += 1 }
        }
        return standing
    }

    // What a session is called and what colour it wears, worked out once so a row, a
    // resume card and a block on the band cannot disagree about either.
    private struct Identity {
        let name: String
        let tint: Theme.ProjectTint
        let avatar: SidebarAvatar
    }

    private func identity(of session: ChatSession) -> Identity {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let project = store.project(session.projectID)
        let name = workspace?.name ?? project?.name ?? "Unknown project"
        let avatar = if let workspace {
            workspace.sidebarAvatar
        } else if let project {
            project.sidebarAvatar
        } else {
            SidebarAvatar(subject: .project, id: session.projectID)
        }
        // A workspace is not one repository, so it sits outside the project wheel rather
        // than being split across the projects it holds.
        let fallbackTint = workspace == nil
            ? Theme.projectTint(for: name)
            : Theme.workspaceTint
        return Identity(
            name: name,
            tint: avatar.identityTint(iconSet: appSettings.sidebarIconSet,
                                      style: appSettings.diceBearAvatarStyle,
                                      name: name,
                                      monogramTint: fallbackTint),
            avatar: avatar)
    }

    private func describe(_ session: ChatSession, identity: Identity, live: ChatSession,
                          busy: Bool, permission: PermissionRequest?,
                          finished: Bool) -> HomeLive {
        let waiting = runner.state(live.id) == .waiting
        let checkouts = store.checkoutProjects(for: session)
        return HomeLive(
            session: session,
            containerName: identity.name,
            tint: identity.tint,
            avatar: identity.avatar,
            tone: SessionTone(busy: busy, needsInput: permission != nil, finished: finished,
                              waiting: waiting, waitIsStale: runner.waitIsStale(live.id)),
            activity: SessionActivity.line(
                permission: permission,
                runningTool: busy ? runner.runningTool(live.id) : nil,
                root: store.workingDirectory(for: session) ?? "",
                lastTool: live.summary.lastTool,
                finished: finished,
                backgroundTasks: runner.backgroundTasks(live.id)),
            location: location(session, checkouts: checkouts),
            destination: live.id == session.id ? .conversation : .design,
            permission: permission,
            finished: finished)
    }

    private func location(_ session: ChatSession, checkouts: [SessionProject]) -> String {
        if checkouts.count > 1 { return "\(checkouts.count) projects" }
        if session.worktreePath != nil { return session.worktreeBranch ?? "worktree" }
        return "project folder"
    }
}

private struct ResumeCard: View {
    let live: HomeLive
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    ProjectDot(tint: live.tint, size: 6)
                    Text(live.containerName.uppercased())
                        .font(.mono(9.5))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(live.session.lastActivity))
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                }
                Text(live.session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    DiffPair(added: live.session.summary.added,
                             removed: live.session.summary.removed, size: 10.5, spacing: 4)
                    Spacer(minLength: 4)
                    Text(live.location)
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(hovering ? Theme.field : Theme.sunken))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this session")
        .hoverLift(hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Empty state

// The case for the app, made once. It only appears while there is no work to report, so
// it never competes with the status screen it is standing in for.
private struct HomeIntroduction: View {
    private let highlights = [
        Highlight(icon: "arrow.triangle.branch",
                  title: "Work in parallel",
                  detail: "Give each session an isolated Git worktree, or let it work directly in the project folder."),
        Highlight(icon: "doc.text.magnifyingglass",
                  title: "See everything that changed",
                  detail: "Follow the conversation, tool activity, files, diffs, token use and terminal without losing context."),
        Highlight(icon: "person.2.fill",
                  title: "Use the right agent",
                  detail: "Start each session with Claude Code, Codex or Copilot and choose its model, reasoning and access settings."),
        Highlight(icon: "wrench.and.screwdriver.fill",
                  title: "Stay in flow",
                  detail: "Answer permissions, manage Git, inspect Docker, send API requests and use MCP tools inside Code Station.")
    ]

    private struct Highlight: Identifiable {
        let icon: String
        let title: String
        let detail: String

        var id: String { title }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 22) {
                    AppMark()
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Run the work. See the whole change.")
                            .font(.serif(30))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Add a project from the rail on the left and Code Station starts reporting on it here: what is running, what is waiting on you, and what you left half done.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 650, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible(minimum: 250), spacing: 14),
                                    GridItem(.flexible(minimum: 250), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(highlights) { highlight in
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: highlight.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.accent.opacity(0.09)))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(highlight.title).font(.serif(17))
                                Text(highlight.detail)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                        .cardSurface(cornerRadius: 12)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
