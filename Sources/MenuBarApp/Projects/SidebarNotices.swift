import SwiftUI

// A session worth naming above the tree, and the few words that say why. The same list
// feeds the NEEDS YOU card and the running count's menu, so the sidebar works it out once
// for the pair rather than building and sorting it twice on every redraw.
struct NoticedSession {
    let session: ChatSession
    let project: Project
    let notice: SessionNotice
    // Why this one is here, in the few words that fit under its title: the tool that is
    // asking, or what the finished turn left behind.
    let reason: String
}

@MainActor
enum SidebarNotices {
    // The activity line is handed in because the session cards work one out too, and a
    // running notice says the same thing the card would.
    static func all(store: ProjectStore, runner: SessionRunner,
                    activity: (ChatSession) -> String?) -> [NoticedSession] {
        store.sidebarSessions.compactMap { session in
            guard let project = store.project(session.projectID) else { return nil }
            let live = LiveConversation.id(of: session.id, store: store, runner: runner)
            let question = runner.question(live)
            guard let notice = SessionNotice(
                isBusy: runner.state(live).isBusy,
                needsInput: question != nil,
                finishedUnseen: store.hasFinished(session.id)) else { return nil }
            return NoticedSession(session: session, project: project, notice: notice,
                                  reason: reason(notice, question: question,
                                                 activity: activity(session)))
        }
        .sorted(by: comesFirst)
    }

    // Whatever is waiting on a person leads, since that is the only kind anyone has to
    // act on. Within a kind the session touched most recently leads, so the rail reads
    // newest first the way the cards under it do.
    static func comesFirst(_ first: NoticedSession, _ second: NoticedSession) -> Bool {
        if first.notice != second.notice { return first.notice.rawValue < second.notice.rawValue }
        return first.session.lastActivity > second.session.lastActivity
    }

    static func reason(_ notice: SessionNotice, question: PermissionRequest?,
                       activity: String?) -> String {
        switch notice {
        case .needsInput:
            guard let question else { return "waiting on an answer" }
            return question.isQuestion
                ? "question · \(question.title.lowercased())"
                : "permission · \(question.toolName.lowercased())"
        case .running:
            return activity ?? "running"
        case .finished:
            return "finished while away"
        }
    }

    // The menu behind the running count. The list is already grouped by kind, so a rule
    // between two neighbours of different kinds is all the separation it needs.
    static func menu(_ notices: [NoticedSession], store: ProjectStore,
                     isSelected: (ChatSession) -> Bool,
                     open: @escaping (ChatSession) -> Void) -> [MenuEntry] {
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
                    open(noticed.session)
                })
        }
        return entries
    }
}

extension SessionNotice {
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

// MARK: - The rail's header

// The app's own row: home, the one number worth carrying at the very top, and the phone
// badge. The running count is the reason to look at the rail at all, so it sits here
// rather than being found by opening the project it belongs to.
struct SidebarBrandBar: View {
    let runningCount: Int
    let isHome: Bool
    let selectHome: () -> Void
    let noticeMenu: () -> [MenuEntry]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: selectHome) {
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
                    .fill(isHome || hovering ? Theme.card : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isHome ? Theme.border : Color.clear, lineWidth: 1.3))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hovering = $0 }
            .appTooltip("Home")

            Spacer(minLength: 4)

            if runningCount > 0 {
                HStack(spacing: 5) {
                    RunningDot()
                    Text("\(runningCount)")
                        .font(.mono(9.5, .semibold))
                        .kerning(0.7)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.1)))
                .appMenu(noticeMenu)
                .appTooltip("Show active and unread sessions")
            }

            MobileAccessBadge()
        }
        .padding(.horizontal, 14)
        .headerBand(Theme.sidebar)
    }
}

// Permission prompts and turns that ended while the user was away are the only things in
// the app that are waiting on a person, so they sit above the tree rather than being
// found by opening the project they happen to belong to. Shown only when there is
// something waiting; the sidebar leaves it out otherwise.
struct SidebarNeedsYouCard: View {
    let waiting: [NoticedSession]
    let open: (ChatSession) -> Void

    // Three is what fits above the tree without pushing the projects off screen. The
    // count in the heading is the whole number, so a longer queue still says how long.
    private static let shown = 3

    var body: some View {
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
                ForEach(waiting.prefix(Self.shown), id: \.session.id) { noticed in
                    row(noticed)
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

    private func row(_ noticed: NoticedSession) -> some View {
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
                open(noticed.session)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(noticed.session) }
    }
}
