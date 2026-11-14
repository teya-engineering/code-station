import SwiftUI

enum SessionSnoozeMenu {
    @MainActor
    static func entries(for session: ChatSession, store: ProjectStore,
                        dialogs: DialogPresenter) -> [MenuEntry] {
        let snoozed = store.isSnoozed(session.id)
        var entries: [MenuEntry] = []
        if snoozed {
            entries.append(.item("Wake up", icon: "bell") { wake(session.id, store: store) })
        }
        entries.append(.item(snoozed ? "Change snooze…" : "Snooze…", icon: "moon.zzz") {
            dialogs.show(SessionSnoozeDialog.make(for: session, store: store))
        })
        return entries
    }

    @MainActor
    static func wake(_ sessionID: UUID, store: ProjectStore) {
        store.wake(sessionID)
        AccessibilityNotification.Announcement("Session awake. Notifications are back on.").post()
    }
}

@MainActor
@Observable
final class SnoozeChoice {
    var choice: SessionSnooze.Choice
    let now: Date

    init(snooze: SessionSnooze? = nil, now: Date = Date()) {
        self.now = now
        choice = SessionSnooze.Choice.allCases.first { $0.snooze(now: now) == snooze } ?? .morning
    }
}

enum SessionSnoozeDialog {
    static let title = "Snooze this session"

    @MainActor
    static func make(for session: ChatSession, store: ProjectStore) -> Dialog {
        let picked = SnoozeChoice(snooze: store.snooze(of: session.id))
        let confirm = Dialog.Action(label: "Snooze session", kind: .primary) {
            let snooze = picked.choice.snooze(now: picked.now)
            store.snooze(session.id, snooze)
            AccessibilityNotification.Announcement(
                "Snoozed \(snooze.phrase()). The agent keeps working.").post()
        }
        var dialog = Dialog(title: title, actions: [confirm])
        dialog.content = AnyView(SnoozeDialogContent(title: session.title, picked: picked, confirm: confirm))
        dialog.width = 500
        dialog.cornerRadius = 18
        dialog.isModal = true
        dialog.framesItself = true
        return dialog
    }
}

// Laid out like the impact dialog, so a snooze reads as one more question from the
// same app: the session it is about, the question, one row per answer, and the buttons
// on a band at the foot.
private struct SnoozeDialogContent: View {
    let title: String
    @Bindable var picked: SnoozeChoice
    let confirm: Dialog.Action
    @Environment(DialogPresenter.self) private var dialogs
    @FocusState private var focused: Focus?

    private enum Focus: Hashable {
        case choice(SessionSnooze.Choice), cancel, confirm
    }

    private let choices = SessionSnooze.Choice.allCases

    // Rows follow 70 ms apart, on the same clock as the impact dialog's rows.
    private func rowStart(_ index: Int) -> Double { 0.18 + Double(index) * 0.07 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxl) {
                subject.arrives(after: 0.05, rising: 4)
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(SessionSnoozeDialog.title)
                        .font(Typography.display.weight(.regular))
                        .accessibilityAddTraits(.isHeader)
                    Text("The agent keeps working, but its notifications stay quiet until the time you pick.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .arrives(after: 0.09, rising: 4)
                VStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                        Rectangle().fill(Theme.border).frame(height: 1)
                            .draws(after: rowStart(index))
                        row(choice, arrivingAfter: rowStart(index))
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                        .draws(after: rowStart(choices.count))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Snooze until")
                Label("If the agent asks you something, the session wakes up straight away.",
                      systemImage: "info.circle")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .arrives(after: rowStart(choices.count) + 0.06)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xxxl)
            HStack(spacing: Space.md) {
                Spacer(minLength: 0)
                ActionButton(title: "Cancel", tone: .sunken, height: ControlHeight.xl, size: Typography.Size.detail,
                             keyboardShortcut: .cancelAction) {
                    dialogs.dismiss()
                }
                .focused($focused, equals: .cancel)
                .focusEffectDisabled()
                .overlay(FocusRingStroke(focused: focused == .cancel))
                ActionButton(title: confirm.label, tone: .dark, height: ControlHeight.xl, size: Typography.Size.detail,
                             keyboardShortcut: .defaultAction) {
                    dialogs.run(confirm)
                }
                .focused($focused, equals: .confirm)
                .focusEffectDisabled()
                .overlay(FocusRingStroke(focused: focused == .confirm))
            }
            .padding(Space.xxl)
            .background(Theme.field)
            .arrives(after: 0.06)
        }
        .background(Theme.card)
        .onKeyPress(keys: [.tab]) { press in
            let stops: [Focus] = [.choice(picked.choice), .cancel, .confirm]
            let index = stops.firstIndex { $0 == focused } ?? 0
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focused = stops[(index + step + stops.count) % stops.count]
            return .handled
        }
        .onExitCommand { dialogs.dismiss() }
        .onAppear { focused = .choice(picked.choice) }
        .onDisappear { dialogs.restoreFocus() }
    }

    // The session's title stays on one line, so a long prompt pasted as the title does
    // not push the question down the card.
    private var subject: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "moon")
                .font(.system(size: 14))
                .foregroundStyle(Theme.snoozeText)
                .frame(width: 29, height: 29)
                .background(Theme.snoozeSurface, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.snoozeEdge, lineWidth: 0.7))
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func row(_ choice: SessionSnooze.Choice, arrivingAfter start: Double) -> some View {
        let selected = picked.choice == choice
        return Button {
            picked.choice = choice
            focused = .choice(choice)
        } label: {
            HStack(spacing: Space.lg) {
                Image(systemName: choice.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.snoozeText : Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(selected ? Theme.snoozeSurface : Theme.field, in: Circle())
                    .motion(Motion.control, value: selected)
                    .arrives(after: start + 0.04)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(choice.title(now: picked.now)).font(Typography.body.weight(.medium))
                    Text(choice.note(now: picked.now))
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .arrives(after: start + 0.06, sliding: 6)
                Spacer(minLength: 0)
                SnoozeRadio(selected: selected)
                    .arrives(after: start + 0.06)
            }
            .padding(.vertical, Space.lg)
            .padding(.horizontal, Space.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.card)
        .padding(.horizontal, -10)
        .focused($focused, equals: .choice(choice))
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focused == .choice(choice)).padding(.horizontal, -10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.title(now: picked.now))
        .accessibilityValue(choice.note(now: picked.now))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let index = choices.firstIndex(of: choice) ?? 0
            let step = press.key == .leftArrow || press.key == .upArrow ? -1 : 1
            let next = choices[(index + step + choices.count) % choices.count]
            picked.choice = next
            focused = .choice(next)
            return .handled
        }
    }
}

private struct SnoozeRadio: View {
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(selected ? Theme.snoozeText : Theme.secondaryText.opacity(0.35), lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .overlay {
                // Lands from half size, never from zero, and only fades under Reduce Motion.
                Circle()
                    .fill(Theme.snoozeText)
                    .frame(width: 8, height: 8)
                    .scaleEffect(selected || reduceMotion ? 1 : 0.5)
                    .opacity(selected ? 1 : 0)
                    .motion(Motion.pop, value: selected)
            }
            .motion(Motion.control, value: selected)
            .accessibilityHidden(true)
    }
}

// Says so when a timed snooze runs out, since nothing else about the session changes
// when it does. It waits for any other dialog to be put away first, and every session
// that came back while it waited is told of in one go.
struct SnoozeReminder: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: store.snoozeReminders.count, initial: true) { present() }
            .onChange(of: dialogs.current?.id) { present() }
    }

    private func present() {
        guard dialogs.current == nil, !store.snoozeReminders.isEmpty else { return }
        let due = store.takeSnoozeReminders()
        guard let first = due.first else { return }
        if due.count == 1 {
            dialogs.show(Dialog(
                title: "\"\(first.session.title)\" is back",
                message: "It was snoozed \(first.snooze.phrase()). It can notify you again.",
                actions: [
                    .init(label: "Open session", kind: .primary) {
                        store.selectSession(first.session.id)
                    },
                    .init(label: "Snooze again") {
                        dialogs.show(SessionSnoozeDialog.make(for: first.session, store: store))
                    },
                    .init(label: "OK", kind: .cancel),
                ]))
        } else {
            var dialog = Dialog(
                title: "\(due.count) sessions are back",
                message: "Their snoozes have ended. They can notify you again.",
                actions: [.init(label: "OK", kind: .cancel)])
            dialog.content = AnyView(SessionTitleList(titles: due.map(\.session.title)))
            dialogs.show(dialog)
        }
    }
}

struct SessionSnoozePocket: View {
    let snooze: SessionSnooze
    let wake: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "moon")
                .font(.system(size: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Snoozed").font(Typography.caption.weight(.semibold))
                Text(snooze.phrase().prefix(1).uppercased() + snooze.phrase().dropFirst())
                    .font(Font.system(size: Typography.Size.micro))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            SnoozeWakeButton(compact: true, wake: wake)
                .accessibilityHint("Restores notifications. The agent keeps working.")
        }
        .foregroundStyle(Theme.snoozeText)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, minHeight: 49)
        .background(Theme.snoozeSurface)
        .overlay(alignment: .top) { Theme.snoozeEdge.frame(height: 0.7) }
        .motion(Motion.control, value: snooze)
    }
}

struct SessionSnoozeStrip: View {
    let snooze: SessionSnooze
    let wake: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "moon")
                .font(.system(size: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Snoozed \(snooze.phrase())")
                    .font(Typography.label)
                    .contentTransition(.opacity)
                Text("The agent keeps working.")
                    .font(Typography.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            SnoozeWakeButton(wake: wake)
        }
        .foregroundStyle(Theme.snoozeText)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .surface(Theme.snoozeSurface, cornerRadius: Radius.control, border: Theme.snoozeEdge)
        .motion(Motion.control, value: snooze)
    }
}

private struct SnoozeWakeButton: View {
    var compact = false
    let wake: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: wake) {
            Text("Wake up")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(Theme.snoozeText)
                .fixedSize()
                .padding(.horizontal, compact ? 5 : 10)
                .padding(.vertical, Space.sm)
                .background(hovering ? Theme.snoozeText.opacity(0.08) : .clear, in: Capsule())
                .overlay(Capsule().stroke(compact ? .clear : Theme.snoozeEdge, lineWidth: 0.7))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sidebarFocusRing()
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}
