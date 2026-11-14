import SwiftUI

// What opens beside a session on the orbit map: what it is doing or asking, how far it has
// got, and the buttons to answer it from here.
struct OrbitSessionCard: View {
    let live: HomeLive
    let hasChanges: Bool
    let workTime: TimeInterval
    let open: (SessionDestination) -> Void
    let answer: (PermissionAnswer) -> Void
    let reveal: () -> Void
    let close: () -> Void

    static let width: CGFloat = 330

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                SidebarIdentityTile(avatar: live.avatar, name: live.containerName, tint: live.tint,
                                    stacked: live.session.workspaceID != nil, side: 18)
                    .accessibilityHidden(true)
                Text(live.containerName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(live.session.agent.title)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                GlyphButton(icon: "xmark", side: ControlHeight.xs, action: close)
                    .accessibilityLabel("Close")
            }
            .font(Typography.detail)
            Text(live.session.title)
                .font(Typography.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.md)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: Space.sm) {
                    MapLight(tone: live.tone)
                    Text(statusLine)
                }
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            }
            .padding(.top, Space.sm)
            now.padding(.top, Space.md)
            facts.padding(.top, Space.md)
            actions.padding(.top, Space.lg)
        }
        .padding(Space.lg)
        .frame(width: Self.width, alignment: .leading)
        .floatingCard(cornerRadius: Radius.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(live.session.title)
    }

    private var statusLine: String {
        guard let permission = live.permission else { return live.status }
        return "\(live.status) for \(RelativeTime.duration(since: permission.askedAt))"
    }

    // What the session is asking, or what it is busy with right now.
    @ViewBuilder private var now: some View {
        if let permission = live.permission {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let question = permission.questions.first {
                    Text(question.text).lineLimit(4)
                } else {
                    Text(permission.title)
                    Text(permission.subjectIsMarkdown
                         ? permission.subject.components(separatedBy: .newlines).first ?? ""
                         : permission.subject)
                        .font(Typography.data)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
            .font(Typography.detail)
            .foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.attention.opacity(0.12)))
        } else {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let caption {
                    Text(caption)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(live.finished ? "Finished." : live.activity)
                    .font(Typography.code)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.sunken))
        }
    }

    private var caption: String? {
        switch live.tone {
        case .running: "Right now"
        case .waiting: "Waiting for"
        case .needsYou, .idle: nil
        }
    }

    private var facts: some View {
        let summary = live.session.summary
        let started = live.session.createdAt
        return HStack(alignment: .top, spacing: Space.md) {
            fact("Started") {
                Text(Calendar.current.isDateInToday(started)
                     ? started.formatted(date: .omitted, time: .shortened)
                     : RelativeTime.stamp(started))
            }
            fact("Working for") { Text(Self.duration(workTime)) }
            fact("Changes") {
                DiffPair(added: summary.added, removed: summary.removed, size: Typography.Size.detail, spacing: Space.xs)
            }
        }
    }

    private func fact(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
            value()
                .font(Typography.body.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // "12m", "1h 05m": time spent working reads in minutes, since a turn is rarely shorter.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h " + String(format: "%02dm", minutes % 60)
    }

    @ViewBuilder private var actions: some View {
        let quick = live.quickAnswers
        let primary = live.primaryAction(hasChanges: hasChanges)
        HStack(spacing: Space.sm) {
            if !quick.isEmpty || primary.destination != live.destination {
                ActionButton(title: "Open session", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail) {
                    open(live.destination)
                }
            }
            if !quick.isEmpty {
                ForEach(quick.indices, id: \.self) { index in
                    ActionButton(title: quick[index].title, tone: index == 0 ? .green : .outlined,
                                 height: ControlHeight.sm, size: Typography.Size.detail) { answer(quick[index].answer) }
                }
            } else {
                ActionButton(title: primary.title, tone: .green, height: ControlHeight.sm, size: Typography.Size.detail) {
                    open(primary.destination)
                }
                if !live.needsAttention {
                    ActionButton(title: "Show in sidebar", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail, action: reveal)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
