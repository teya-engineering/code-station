import SwiftUI

struct OldSessionsSettings: View {
    let review: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs

    @State private var narrow = false
    @State private var undo: (() -> Void)?
    @State private var note = TransientNote()
    @State private var changedRow: String?
    @State private var saves = 0
    @State private var invalidRows: Set<String> = []
    @FocusState private var helpFocused: Bool

    var body: some View {
        ChoiceBlock("OLD SESSIONS") {
            HStack(alignment: .top, spacing: Space.md) {
                Text("Choose when each kind of session is old, and what happens next.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(automaticCount) of 6 on auto-delete")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .fixedSize()
                GlyphButton(icon: "questionmark", action: showHelp)
                    .appTooltip("How old session rules work")
                    .accessibilityLabel("How old session rules work")
                    .focused($helpFocused)
            }
            .motion(Motion.pop, value: automaticCount)

            SettingsCard {
                if !narrow {
                    HStack(spacing: Space.lg) {
                        Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                        Label("Old after", systemImage: "clock")
                            .frame(width: SettingsRuleMetrics.ageWidth, alignment: .leading)
                        Text("Auto-delete")
                            .frame(width: SettingsRuleMetrics.actionWidth, alignment: .leading)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(Space.lg)
                    .background(Theme.sunken)
                    .accessibilityHidden(true)
                    SettingsRowDivider()
                }
                ruleRow(nil)
                ForEach(CleanupReason.allCases) { reason in
                    SettingsRowDivider()
                    ruleRow(reason)
                }
                SettingsRowDivider()
                Label {
                    Text("**Auto-delete on:** a one-hour countdown in the sidebar. **Off:** wait for your review.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock").foregroundStyle(Theme.accent)
                }
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .background(Theme.sunken)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Days count from the last turn. Pinned, open and running sessions are always kept.",
                      systemImage: "shield")
                Label("The longest matching period wins. If any matching rule has auto-delete off, you review first.",
                      systemImage: "square.3.layers.3d")
            }
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) { saveStatus; Spacer(minLength: 0); reviewButton }
                VStack(alignment: .leading, spacing: Space.md) { saveStatus; reviewButton }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < SettingsRuleMetrics.stackedWidth } action: {
            narrow = $0
        }
        .headerNote(note, top: Space.md)
    }

    private var automaticCount: Int {
        (settings.oldSessionsDeleteOnTheirOwn ? 1 : 0)
            + CleanupReason.allCases.count { !settings.cleanupRule.asks($0) }
    }

    private func ruleRow(_ reason: CleanupReason?) -> some View {
        let title = reason?.title ?? "All other sessions"
        return OldSessionRuleRow(
            reason: reason, narrow: narrow,
            onValidityChange: { valid in
                let id = reason?.rawValue ?? "other"
                if valid { invalidRows.remove(id) } else { invalidRows.insert(id) }
            },
            changed: changedRow == (reason?.rawValue ?? "other") && note.text != nil,
            days: Binding(get: { settings.cleanupRule.age(for: reason) }, set: { days in
                let previous = settings.cleanupRule.age(for: reason)
                guard previous != days else { return }
                setDays(days, for: reason)
                saved("\(title): old after \(counted(days, "day"))", reason: reason) {
                    setDays(previous, for: reason)
                }
            }),
            autoDelete: Binding(get: {
                reason.map { !settings.cleanupRule.asks($0) } ?? settings.oldSessionsDeleteOnTheirOwn
            }, set: { enabled in
                setAutoDelete(enabled, for: reason)
                saved("\(title): \(enabled ? "auto-delete on" : "review first")", reason: reason) {
                    setAutoDelete(!enabled, for: reason)
                }
            }))
    }

    private func setDays(_ days: Int, for reason: CleanupReason?) {
        if let reason { settings.oldSessionConditionDays[reason] = days }
        else { settings.oldSessionDays = days }
    }

    private func setAutoDelete(_ enabled: Bool, for reason: CleanupReason?) {
        if let reason {
            if enabled { settings.oldSessionAskReasons.remove(reason) }
            else { settings.oldSessionAskReasons.insert(reason) }
        } else {
            settings.oldSessionsDeleteOnTheirOwn = enabled
        }
    }

    private func saved(_ message: String, reason: CleanupReason?, undo: @escaping () -> Void) {
        self.undo = undo
        changedRow = reason?.rawValue ?? "other"
        saves += 1
        note.show(message, icon: "checkmark")
        AccessibilityNotification.Announcement(message + ". Changes saved.").post()
    }

    private var saveStatus: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: invalidRows.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(invalidRows.isEmpty ? Theme.accent : Theme.warningText)
                .contentTransition(.symbolEffect(.replace))
                .actOut("checkmark", trigger: saves)
            Text(invalidRows.isEmpty ? (saves == 0 ? "Changes saved automatically" : "All changes saved")
                 : "Enter 1 to 30 whole days")
                .foregroundStyle(invalidRows.isEmpty ? .secondary : Theme.warningText)
                .contentTransition(.opacity)
            if let undo {
                InlineLink(title: "Undo") {
                    undo()
                    self.undo = nil
                    saves += 1
                    note.show("Last change undone", icon: "arrow.uturn.backward")
                    AccessibilityNotification.Announcement("Last change undone. Changes saved.").post()
                }
                .transition(.fadeIn)
            }
        }
        .font(Typography.caption)
        .motion(Motion.pop, value: saves)
        .motion(Motion.control, value: invalidRows.isEmpty)
    }

    private var reviewButton: some View {
        ActionButton(title: "Review old sessions", tone: .outlined, icon: "list.clipboard", action: review)
    }

    private func showHelp() {
        var dialog = Dialog.notice("How old session rules work", message:
            "Set 1 to 30 days from a session's last turn. With auto-delete off, that is when it appears for review and it stays until you decide.\n\n"
            + "Auto-delete on starts the existing one-hour sidebar countdown. You can keep a session during that hour.\n\n"
            + "When conditions overlap, the longest period applies and every matching switch must be on for auto-delete. All other sessions applies only when no conditions match.\n\n"
            + "Pinned, open and running sessions are excluded. Project snoozes and ask-again-later deferrals still hold off cleanup.")
        dialog.width = FormMetrics.dialogWidth
        dialog.isModal = true
        dialog.onCancel = { helpFocused = true }
        dialog.actions = [.init(label: "Got it", kind: .cancel, handler: { helpFocused = true })]
        dialogs.show(dialog)
    }
}

private struct OldSessionRuleRow: View {
    let reason: CleanupReason?
    let narrow: Bool
    let onValidityChange: (Bool) -> Void
    let changed: Bool
    @Binding var days: Int
    @Binding var autoDelete: Bool

    private var title: String { reason?.title ?? "All other sessions" }
    private var warns: Bool { reason?.family == .losesWork }

    var body: some View {
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.lg))
            : AnyLayout(HStackLayout(spacing: Space.lg))
        layout {
            identity
            HStack(alignment: .top, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if narrow {
                        Text("Old after").font(Typography.caption).foregroundStyle(.secondary)
                    }
                    age
                }
                if narrow { Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: Space.xs) {
                    if narrow {
                        Text("Auto-delete").font(Typography.caption).foregroundStyle(.secondary)
                    }
                    choice
                }
            }
            .fixedSize(horizontal: !narrow, vertical: false)
        }
        .padding(Space.lg)
        .background(changed ? Theme.accent.opacity(0.12) : reason == nil ? Theme.accent.opacity(0.05) : .clear)
        .hoverFill(cornerRadius: Radius.inset)
        .motion(Motion.control, value: changed)
        .motion(Motion.control, value: autoDelete)
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: Space.lg) {
            IconBadge(icon: icon, tint: tint, side: ControlHeight.lg)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.md) {
                    Text(title).font(Typography.body.weight(.semibold))
                    if reason == nil { MonoChip(text: "Default") }
                }
                Text(reason?.detail ?? "No conditions below apply.")
                    .font(Typography.detail)
                    .foregroundStyle(warns && autoDelete ? Theme.attentionText : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var age: some View {
        DayField(days: $days, accessibilityLabel: "\(title): old after, in days", validatesEntry: true,
                 onValidityChange: onValidityChange)
            .frame(width: SettingsRuleMetrics.ageWidth, alignment: .leading)
    }

    private var choice: some View {
        Toggle(isOn: $autoDelete) {
            Text(autoDelete ? "On" : "Off, review first")
                .font(Typography.detail)
                .foregroundStyle(autoDelete ? (warns ? Theme.attentionText : Theme.accent) : .secondary)
                .contentTransition(.opacity)
        }
        .toggleStyle(.appSwitch(warns: warns, leading: true))
        .accessibilityLabel("Auto-delete \(title.lowercased())")
        .accessibilityValue(autoDelete ? "On" : "Off, review first")
        .accessibilityHint(reason?.detail ?? "Applies when no other condition matches.")
        .frame(width: SettingsRuleMetrics.actionWidth, height: ControlHeight.lg, alignment: .leading)
    }

    private var icon: String {
        switch reason {
        case .uncommittedChanges: "point.3.connected.trianglepath.dotted"
        case .unpushedCommits: "square.and.arrow.up"
        case .unbuiltDesign: "rectangle.split.2x2"
        case .unread: "text.bubble"
        case .snoozed: "moon"
        case nil: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch reason {
        case .unbuiltDesign, .snoozed: Theme.snoozeText
        case nil: Theme.accent
        default: .secondary
        }
    }
}

// A reason, in the colour of its family: red for work that would be lost, amber for
// something not looked at yet, the snooze lilac for something put aside. Uncommitted
// changes show the diff itself once it is known, since the lines are the cost.
struct CleanupReasonChip: View {
    let text: String
    let reason: CleanupReason
    var diff: (added: Int, removed: Int)? = nil

    var body: some View {
        Group {
            if reason == .uncommittedChanges, let diff {
                DiffPair(added: diff.added, removed: diff.removed)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.tag))
                    .appTooltip("Not committed")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(counted(diff.added, "line")) added, \(diff.removed) removed, not committed")
            } else {
                Text(text)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(background, in: RoundedRectangle(cornerRadius: Radius.tag))
            }
        }
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
