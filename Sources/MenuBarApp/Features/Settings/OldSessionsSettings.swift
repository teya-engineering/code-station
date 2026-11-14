import SwiftUI

// When a session counts as old, whether old sessions go on their own, and what always
// needs a yes first.
struct OldSessionsSettings: View {
    let review: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(OrphanedWorktreeMonitor.self) private var orphans

    var body: some View {
        @Bindable var settings = settings
        return ChoiceBlock("OLD SESSIONS") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    copy(title: "Count a session as old after",
                         detail: "Counted from its last turn. Pinned, open and running sessions never count.")
                    Spacer(minLength: 0)
                    DayField(days: $settings.oldSessionDays)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)

                SettingsRowDivider()

                SettingsToggleRow(
                    "Delete old sessions on their own",
                    detail: "Old sessions go after a one-hour countdown in the sidebar, unless the list below asks first. Turn this off to only ever delete from the review screen.",
                    isOn: $settings.oldSessionsDeleteOnTheirOwn)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)

                SettingsRowDivider()

                askList
                    .disabled(!settings.oldSessionsDeleteOnTheirOwn)
                    .opacity(settings.oldSessionsDeleteOnTheirOwn ? 1 : 0.45)
                    .motion(Motion.control, value: settings.oldSessionsDeleteOnTheirOwn)

                reviewRow
            }
        }
    }

    private var askList: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            copy(title: "Ask me first when a session has",
                 detail: "These are never deleted on their own. Once old, they wait in the sidebar until you say yes.")
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(CleanupReason.allCases) { reason in
                    AskReasonRow(reason: reason,
                                 isOn: Binding(
                                    get: { settings.cleanupRule.asks(reason) },
                                    set: { setAsked(reason, $0) }))
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setAsked(_ reason: CleanupReason, _ asked: Bool) {
        if asked {
            settings.oldSessionAskReasons.insert(reason)
        } else {
            settings.oldSessionAskReasons.remove(reason)
        }
    }

    private var reviewRow: some View {
        let nothingOld = !hasAnythingOld
        return VStack(spacing: 0) {
            Rectangle().fill(Theme.settingsHairline).frame(height: 1)
            HStack {
                Spacer(minLength: 0)
                InlineLink(title: "Review old sessions…", action: review)
                    .disabled(nothingOld)
                    .opacity(nothingOld ? 0.4 : 1)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
    }

    private var hasAnythingOld: Bool {
        let old = OldSessionSweep.due(
            days: settings.oldSessionDays, in: store.sidebarSessions,
            isBusy: { runner.isBusy($0, store: store) },
            isOpen: { store.selection == .session($0) },
            snoozedUntil: { store.snoozeDeadline(for: $0) })
        return !old.isEmpty
            || (settings.cleanupRule.includesOrphans && !orphans.cleanupCandidates().isEmpty)
    }

    private func copy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(Typography.body.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// One reason on the ask list.
private struct AskReasonRow: View {
    let reason: CleanupReason
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .toggleStyle(.appCheckbox)
            .accessibilityLabel(reason.title)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(reason.title)
                .font(Typography.body.weight(.semibold))
            Text(reason.detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// A reason, in the colour of its family: red for work that would be lost, amber for
// something not looked at yet, the snooze lilac for something put aside.
struct CleanupReasonChip: View {
    let text: String
    let reason: CleanupReason

    var body: some View {
        Text(text)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.inset))
            .fixedSize()
    }

    private var foreground: Color {
        switch reason {
        case .snoozed: Theme.snoozeText
        case .unread: Theme.attentionText
        default: Theme.warningText
        }
    }

    private var background: Color {
        switch reason {
        case .snoozed: Theme.snoozeSurface
        case .unread: Theme.attention.opacity(0.14)
        default: Theme.warningBackground
        }
    }
}
