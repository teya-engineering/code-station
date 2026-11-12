import SwiftUI

// When a session counts as old, whether old sessions go on their own, and what always
// needs a yes first. The preview under the list says what the rule would do to the
// sessions there are right now, so a change is seen before it is lived with.
struct OldSessionsSettings: View {
    let review: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(OrphanedWorktreeMonitor.self) private var orphans
    @Environment(\.settingsNote) private var settingsNote

    @State private var costs: [UUID: SessionRemovalCost] = [:]
    @State private var orphanChanges: [String: Bool] = [:]

    var body: some View {
        @Bindable var settings = settings
        let preview = OldSessionSweep.preview(
            days: settings.oldSessionDays, rule: settings.cleanupRule, store: store,
            runner: runner, costs: costs, orphans: orphans.cleanupCandidates(),
            orphanChanges: orphanChanges)

        return ChoiceBlock("OLD SESSIONS") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    copy(title: "Count a session as old after",
                         detail: "Counted from its last turn. Pinned, open and running sessions never count.")
                    Spacer(minLength: 0)
                    DayField(days: $settings.oldSessionDays)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                SettingsRowDivider()

                SettingsToggleRow(
                    "Delete old sessions on their own",
                    detail: "Read sessions with nothing to lose go after a one-hour countdown in the sidebar. Turn this off to only ever delete from the review screen.",
                    isOn: $settings.oldSessionsDeleteOnTheirOwn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                SettingsRowDivider()

                askList
                    .disabled(!settings.oldSessionsDeleteOnTheirOwn)
                    .opacity(settings.oldSessionsDeleteOnTheirOwn ? 1 : 0.45)
                    .motion(Motion.control, value: settings.oldSessionsDeleteOnTheirOwn)

                previewRow(preview)
            }
        }
        .task(id: settings.oldSessionDays) { await loadCosts() }
    }

    private var askList: some View {
        VStack(alignment: .leading, spacing: 10) {
            copy(title: "Ask me first when a session has",
                 detail: "These are never deleted on their own. Once old, they wait in the sidebar until you say yes.")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(CleanupReason.allCases) { reason in
                    AskReasonRow(reason: reason,
                                 isOn: Binding(
                                    get: { settings.cleanupRule.asks(reason) },
                                    set: { setAsked(reason, $0) }),
                                 explainLock: {
                                     settingsNote("\(reason.title): always asked, since it cannot be undone",
                                                  "lock")
                                 })
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setAsked(_ reason: CleanupReason, _ asked: Bool) {
        guard !reason.isAlwaysAsked else { return }
        if asked {
            settings.oldSessionAskReasons.insert(reason)
        } else {
            settings.oldSessionAskReasons.remove(reason)
        }
    }

    private func previewRow(_ preview: OldSessionSweep.Preview) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.settingsHairline).frame(height: 1)
            HStack(spacing: 0) {
                PreviewCount(count: preview.goes, tint: Theme.deletion,
                             label: "would go after the warning hour")
                Rectangle().fill(Theme.settingsHairline).frame(width: 1)
                PreviewCount(count: preview.waits, tint: Theme.attentionText,
                             label: "would wait for your OK")
                Rectangle().fill(Theme.settingsHairline).frame(width: 1)
                PreviewCount(count: preview.stays, tint: Theme.dotOnText,
                             label: "not old yet, pinned or running")
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.field.opacity(0.5))
            Rectangle().fill(Theme.settingsHairline).frame(height: 1)
            HStack {
                Spacer(minLength: 0)
                InlineLink(title: "Review old sessions…", action: review)
                    .disabled(preview.goes + preview.waits == 0)
                    .opacity(preview.goes + preview.waits == 0 ? 0.4 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the rule would do now")
    }

    private func copy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadCosts() async {
        let loaded = await OldSessionSweep.previewCosts(
            days: settings.oldSessionDays, store: store, runner: runner,
            orphans: orphans.cleanupCandidates())
        guard !Task.isCancelled else { return }
        costs = loaded.sessions
        orphanChanges = loaded.orphans
    }
}

// One reason on the ask list. A reason that is always asked keeps its tick and says
// "Always" instead of naming its family, since there is no choice to make.
private struct AskReasonRow: View {
    let reason: CleanupReason
    @Binding var isOn: Bool
    let explainLock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if reason.isAlwaysAsked {
                Button(action: explainLock) {
                    HStack(alignment: .top, spacing: 8) {
                        CheckboxMark(isOn: true)
                            .opacity(0.5)
                        label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reason.title)
                .accessibilityValue("Always asked")
            } else {
                Toggle(isOn: $isOn) { label }
                    .toggleStyle(.appCheckbox)
                    .accessibilityLabel(reason.title)
            }
            Spacer(minLength: 8)
            CleanupReasonChip(text: reason.isAlwaysAsked ? "Always" : reason.familyTitle,
                              reason: reason)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(reason.title)
                    .font(.system(size: 12.5, weight: .semibold))
                if reason.isNew {
                    Text("New")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.plan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.plan.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(reason.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// One of the three numbers under the ask list. It bumps when it changes, so ticking a
// reason shows at once where the sessions went.
private struct PreviewCount: View {
    let count: Int
    let tint: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)")
                .font(.serif(22))
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(count)))
                .motion(Motion.pop, value: count)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// A reason, in the colour of its family: red for work that would be lost, amber for
// something not looked at yet, the snooze lilac for something put aside.
struct CleanupReasonChip: View {
    let text: String
    let reason: CleanupReason

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
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

extension CleanupReason {
    // The name of the family, as the settings list shows it beside a reason.
    var familyTitle: String {
        switch self {
        case .uncommittedChanges, .unpushedCommits, .unbuiltDesign: "Would lose work"
        case .unread: "Not looked at"
        case .snoozed: "Put aside"
        }
    }

    // Marked so someone who knows the list sees what it can now ask about.
    var isNew: Bool {
        self == .unpushedCommits || self == .snoozed
    }
}
