import SwiftUI

// Turning Stats on and off, and whether sessions that were removed still count. Lives in
// Settings so Home only ever shows numbers.
struct StatsSettings: View {
    @Environment(StatsStore.self) private var stats
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Reach: Hashable {
        case live, past

        var title: String {
            switch self {
            case .live: "Only live sessions"
            case .past: "Include past sessions"
            }
        }
    }

    var body: some View {
        ChoiceBlock("STATS") {
            SettingsCard {
                SettingsToggleRow(
                    "Count where your time goes",
                    detail: "Times, prompts and cost across every project and workspace, never the words. Kept only on this Mac. Turning it off deletes everything Stats kept.",
                    isOn: Binding(get: { settings.statsEnabled }, set: setEnabled))
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)

                if settings.statsEnabled {
                    VStack(spacing: 0) {
                        SettingsRowDivider()
                        reachRow
                        if reach == .past {
                            VStack(spacing: 0) {
                                SettingsRowDivider()
                                daysRow
                            }
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
                        }
                    }
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
                }
            }
            .motion(Motion.reveal, value: settings.statsEnabled)
            .motion(Motion.reveal, value: reach)
        }
        .onAppear { stats.load() }
    }

    private var reach: Reach {
        settings.statsRemovedSessionDays == 0 ? .live : .past
    }

    private var reachRow: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            copy(title: "Sessions counted",
                 detail: "Past sessions are ones you or cleanup removed. Their stats stay for the days you choose.")
            Spacer(minLength: 0)
            OptionMenu(value: reach.title) {
                [Reach.live, .past].map { choice in
                    .item(choice.title, checked: reach == choice) { setReach(choice) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Sessions counted by Stats: \(reach.title)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
    }

    private var daysRow: some View {
        @Bindable var settings = settings
        return HStack(alignment: .top, spacing: Space.lg) {
            copy(title: "Keep past sessions for",
                 detail: keptDetail)
            Spacer(minLength: 0)
            DayField(days: $settings.statsRemovedSessionDays,
                     range: 1...StatsStore.keptDayRange.upperBound,
                     accessibilityLabel: "Days to keep stats for past sessions")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
    }

    private var keptDetail: String {
        let base = "Counted from the session's last turn."
        guard stats.keptCount > 0 else { return base }
        return base + " Keeping \(counted(stats.keptCount, "past session"))."
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

    // MARK: - Actions

    private func setEnabled(_ enabled: Bool) {
        guard !enabled else {
            settings.statsEnabled = true
            stats.turnOn()
            return
        }
        var rows = [Dialog.Impact.Row(title: "Everything Stats counted",
                                      detail: "Times, prompts, waits and costs it worked out")]
        if stats.keptCount > 0 {
            rows.append(Dialog.Impact.Row(title: "Stats for \(counted(stats.keptCount, "past session"))",
                                          detail: "The sessions are gone, so these cannot be worked out again"))
        }
        rows.append(Dialog.Impact.Row(title: "Your sessions",
                                      detail: "Every conversation stays as it is", kept: true))
        dialogs.show(.impact(
            "Turn off Stats?",
            rows: rows,
            warning: "The waits Stats recorded and the stats of past sessions cannot be restored.",
            action: "Turn off and delete") {
                settings.statsEnabled = false
                stats.erase()
            })
    }

    private func setReach(_ choice: Reach) {
        switch choice {
        case .past:
            guard reach == .live else { return }
            settings.statsRemovedSessionDays = StatsStore.defaultKeptDays
        case .live:
            guard reach == .past else { return }
            guard stats.keptCount > 0 else {
                settings.statsRemovedSessionDays = 0
                return
            }
            dialogs.show(.impact(
                "Count only live sessions?",
                rows: [
                    Dialog.Impact.Row(title: "Stats for \(counted(stats.keptCount, "past session"))",
                                      detail: "Their times, prompts and costs"),
                    Dialog.Impact.Row(title: "Stats for live sessions",
                                      detail: "Read again from the sessions themselves", kept: true)
                ],
                warning: "The past sessions are gone, so their stats cannot be restored.",
                compact: true,
                action: "Delete their stats") {
                    settings.statsRemovedSessionDays = 0
                    stats.refresh(store)
                })
        }
    }
}
