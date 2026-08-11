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

    // Recomputed once per redraw and handed down, because every section below counts over
    // the same list of sessions.
    private struct Standing {
        var running: [HomeLive] = []
        var waiting: [HomeLive] = []
        var resumable: [HomeLive] = []
        var addedToday = 0
        var removedToday = 0
        var sessionsToday = 0
        var worktrees = 0
        var worktreeSessions = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.projects.isEmpty && store.workspaces.isEmpty {
                HomeIntroduction()
            } else {
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
                .font(.serif(20, .semibold))
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .uppercased()
                 + " · " + Date().formatted(date: .omitted, time: .shortened))
                .font(.mono(10.5))
                .kerning(0.6)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    // MARK: - Status

    private func status(_ standing: Standing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stats(standing)
                if !standing.waiting.isEmpty { needsYou(standing.waiting) }
                if !standing.running.isEmpty { runningNow(standing.running) }
                if !standing.resumable.isEmpty { resume(standing.resumable) }
                if !oldSessions.isEmpty { cleanup() }
            }
            .padding(24)
        }
    }

    private func stats(_ standing: Standing) -> some View {
        let changed = standing.addedToday > 0 || standing.removedToday > 0
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                         spacing: 12) {
            StatCard(label: "RUNNING",
                     value: "\(standing.running.count)",
                     tone: standing.running.isEmpty ? nil : Theme.addition,
                     note: standing.running.isEmpty
                        ? "Nothing is working right now"
                        : runningNote(standing.running))
            StatCard(label: "NEEDS YOU",
                     value: "\(standing.waiting.count)",
                     tone: standing.waiting.isEmpty ? nil : Theme.attentionText,
                     note: waitingNote(standing.waiting))
            StatCard(label: "CHANGED TODAY",
                     value: changed ? "+\(standing.addedToday) / −\(standing.removedToday)" : "—",
                     tone: nil,
                     note: standing.sessionsToday == 0
                        ? "No sessions have run today"
                        : "across \(standing.sessionsToday) session\(standing.sessionsToday == 1 ? "" : "s")")
            StatCard(label: "WORKTREES",
                     value: "\(standing.worktrees)",
                     tone: nil,
                     note: standing.worktrees == 0
                        ? "Nothing checked out on the side"
                        : "across \(standing.worktreeSessions) session\(standing.worktreeSessions == 1 ? "" : "s")")
        }
    }

    // The projects behind the count, each named once however many sessions it is running.
    private func runningNote(_ running: [HomeLive]) -> String {
        var seen: Set<String> = []
        return running.map(\.containerName).filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    private func waitingNote(_ waiting: [HomeLive]) -> String {
        guard !waiting.isEmpty else { return "Nothing is waiting on you" }
        let permissions = waiting.filter { $0.permission != nil }.count
        let reviews = waiting.count - permissions
        var parts: [String] = []
        if permissions > 0 { parts.append("\(permissions) permission") }
        if reviews > 0 { parts.append("\(reviews) review") }
        return parts.joined(separator: " · ")
    }

    private func needsYou(_ waiting: [HomeLive]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule("NEEDS YOU", dot: Theme.attention, tint: Theme.attentionText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                      spacing: 12) {
                ForEach(waiting.prefix(4)) { live in
                    NeedsYouCard(live: live,
                                 onOpen: { store.selectSession(live.session.id) })
                }
            }
        }
    }

    private func runningNow(_ running: [HomeLive]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule("RUNNING NOW", pulses: true, tint: Theme.addition)
            VStack(spacing: 8) {
                ForEach(running) { live in
                    RunningRow(live: live) { store.selectSession(live.session.id) }
                }
            }
        }
    }

    private func resume(_ resumable: [HomeLive]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule(title: "PICK UP WHERE YOU LEFT OFF") {
                if let first = resumable.first {
                    InlineLink(title: "All sessions →") {
                        store.selectSession(first.session.id)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(resumable.prefix(8)) { live in
                    ResumeCard(live: live) { store.selectSession(live.session.id) }
                }
            }
        }
    }

    private func cleanup() -> some View {
        let stale = oldSessions
        let worktrees = stale.reduce(0) { count, session in
            count + store.checkoutProjects(for: session).compactMap(\.worktreePath).count
        }
        return FooterStrip(
            title: "\(stale.count) session\(stale.count == 1 ? "" : "s") older than \(appSettings.oldSessionDays) days",
            detail: worktrees == 0
                ? "nothing left checked out"
                : "\(worktrees) worktree\(worktrees == 1 ? "" : "s") still checked out") {
            InlineLink(title: "Clean up →", size: 12.5, action: onReviewOldSessions)
        }
    }

    // MARK: - Reading the store

    private var oldSessions: [ChatSession] {
        OldSessions.olderThan(appSettings.oldSessionDays, in: store.sidebarSessions)
            .filter { !runner.state($0.id).isBusy }
    }

    private var standing: Standing {
        var standing = Standing()
        let calendar = Calendar.current

        for session in store.sidebarSessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let busy = runner.state(session.id).isBusy
            let permission = runner.question(session.id)
            let finished = store.hasFinished(session.id)
            let live = describe(session, busy: busy, permission: permission, finished: finished)

            if permission != nil || finished {
                standing.waiting.append(live)
            } else if busy {
                standing.running.append(live)
            } else if session.hasStarted {
                standing.resumable.append(live)
            }

            if calendar.isDateInToday(session.lastActivity) {
                standing.addedToday += session.summary.added
                standing.removedToday += session.summary.removed
                standing.sessionsToday += 1
            }

            let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
            standing.worktrees += worktrees.count
            if !worktrees.isEmpty { standing.worktreeSessions += 1 }
        }
        return standing
    }

    private func describe(_ session: ChatSession, busy: Bool,
                          permission: PermissionRequest?, finished: Bool) -> HomeLive {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let project = store.project(session.projectID)
        let name = workspace?.name ?? project?.name ?? "Unknown project"
        let checkouts = store.checkoutProjects(for: session)
        return HomeLive(
            session: session,
            containerName: name,
            tint: workspace == nil ? Theme.projectTint(for: name) : Theme.workspaceTint,
            tone: SessionTone(busy: busy, needsInput: permission != nil, finished: finished),
            activity: SessionActivity.line(
                permission: permission,
                runningTool: busy ? runner.runningTool(session.id) : nil,
                root: store.workingDirectory(for: session) ?? "",
                lastTool: session.summary.lastTool,
                finished: finished),
            location: location(session, checkouts: checkouts),
            // Nothing reports how far through a turn is, so how full the context window
            // has become is the honest stand-in: it is the one number that only ever grows
            // while a turn runs.
            progress: busy ? (session.usage?.contextFraction(for: session.agent) ?? 0.05) : nil,
            permission: permission)
    }

    private func location(_ session: ChatSession, checkouts: [SessionProject]) -> String {
        if checkouts.count > 1 { return "\(checkouts.count) projects" }
        if session.worktreePath != nil { return session.worktreeBranch ?? "worktree" }
        return "project folder"
    }
}

// One session with everything a row needs already looked up, so a row never reaches back
// into the store while it draws.
private struct HomeLive: Identifiable {
    let session: ChatSession
    let containerName: String
    let tint: Theme.ProjectTint
    let tone: SessionTone
    let activity: String
    let location: String
    // Only a running session has one, since a progress bar on an idle row would be
    // claiming something is still happening.
    let progress: Double?
    let permission: PermissionRequest?

    var id: UUID { session.id }
}

// MARK: - Cards

private struct StatCard: View {
    let label: String
    let value: String
    let tone: Color?
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.serif(32, .medium))
                .foregroundStyle(tone ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

private struct NeedsYouCard: View {
    let live: HomeLive
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProjectDot(tint: live.tint, size: 7)
                Text(live.containerName.uppercased())
                    .font(.mono(10))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                MonoChip(text: live.permission == nil ? "FINISHED" : "PERMISSION",
                         size: 9, tint: Theme.attentionText)
                Text(RelativeTime.short(live.session.lastActivity))
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
            }

            Text(live.session.title)
                .font(.serif(20, .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(live.activity)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ActionButton(title: live.permission == nil ? "Review changes" : "Answer",
                             action: onOpen)
                ActionButton(title: "Open session", tone: .outlined, action: onOpen)
                Spacer(minLength: 6)
                DiffPair(added: live.session.summary.added,
                         removed: live.session.summary.removed, size: 11.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Theme.attention.opacity(0.45), lineWidth: 1.3))
    }
}

private struct RunningRow: View {
    let live: HomeLive
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ProjectDot(tint: live.tint, size: 7)
                Text(live.containerName.uppercased())
                    .font(.mono(10.5))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                Text(live.session.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: 240, alignment: .leading)
                Text(live.activity)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let progress = live.progress {
                    Meter(fraction: progress, colour: Theme.dotOn, height: 4)
                        .frame(width: 92)
                }
                DiffPair(added: live.session.summary.added,
                         removed: live.session.summary.removed)
                Text(RelativeTime.short(live.session.lastActivity))
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(hovering ? Theme.field : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.dotOn.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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
        .animation(.easeOut(duration: 0.12), value: hovering)
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
                  detail: "Start each session with Codex or Claude Code and choose its model, reasoning and access settings."),
        Highlight(icon: "wrench.and.screwdriver.fill",
                  title: "Stay in flow",
                  detail: "Answer permissions, manage Git, inspect Docker, send API requests and use MCP tools inside Conductor.")
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
                        Text("Add a project from the rail on the left and Conductor starts reporting on it here: what is running, what is waiting on you, and what you left half done.")
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
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
