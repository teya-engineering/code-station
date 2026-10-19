import SwiftUI
import CodeStationCore

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
            HStack(spacing: 8) {
                SidebarIdentityTile(avatar: live.avatar, name: live.containerName, tint: live.tint,
                                    stacked: live.session.workspaceID != nil, side: 18)
                    .accessibilityHidden(true)
                Text(live.containerName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(live.session.agent.title)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                CardCloseButton(action: close)
            }
            .font(.system(size: 11.5))
            Text(live.session.title)
                .font(.serif(15, .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 7) {
                    MapLight(tone: live.tone)
                    Text(statusLine)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            now.padding(.top, 10)
            facts.padding(.top, 10)
            actions.padding(.top, 12)
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .floatingCard(cornerRadius: 14)
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
            VStack(alignment: .leading, spacing: 4) {
                if let question = permission.questions.first {
                    Text(question.text).lineLimit(4)
                } else {
                    Text(permission.title)
                    Text(permission.subjectIsMarkdown
                         ? permission.subject.components(separatedBy: .newlines).first ?? ""
                         : permission.subject)
                        .font(.mono(11))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.attention.opacity(0.12)))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(live.finished ? "Finished." : live.activity)
                    .font(.mono(11.5))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
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
        return HStack(alignment: .top, spacing: 8) {
            fact("Started") {
                Text(Calendar.current.isDateInToday(started)
                     ? started.formatted(date: .omitted, time: .shortened)
                     : RelativeTime.stamp(started))
            }
            fact("Working for") { Text(Self.duration(workTime)) }
            fact("Changes") {
                DiffPair(added: summary.added, removed: summary.removed, size: 12, spacing: 4)
            }
        }
    }

    private func fact(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            value()
                .font(.system(size: 12.5, weight: .semibold))
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
        HStack(spacing: 6) {
            if !quick.isEmpty || primary.destination != live.destination {
                ActionButton(title: "Open session", tone: .outlined, height: 26, size: 12) {
                    open(live.destination)
                }
            }
            if !quick.isEmpty {
                ForEach(quick.indices, id: \.self) { index in
                    ActionButton(title: quick[index].title, tone: index == 0 ? .green : .outlined,
                                 height: 26, size: 12) { answer(quick[index].answer) }
                }
            } else {
                ActionButton(title: primary.title, tone: .green, height: 26, size: 12) {
                    open(primary.destination)
                }
                if !live.needsAttention {
                    ActionButton(title: "Show in sidebar", tone: .outlined, height: 26, size: 12, action: reveal)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CardCloseButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .tertiary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.field : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Close")
    }
}
