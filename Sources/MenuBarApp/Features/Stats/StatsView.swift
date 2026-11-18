import SwiftUI

// How the person and their agents spend their time, opened from Tools on Home. Stats are
// off until the person turns them on here, and the sheet says exactly what is counted
// before it asks.
struct StatsView: View {
    @Environment(StatsStore.self) private var stats
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var range = StatsRange.week
    @State private var subject: UUID?
    @State private var report: StatsReport?
    @State private var showsWhy = false
    @State private var keepsRemovedOnStart = false
    @Namespace private var rangeTrack

    private struct BuildKey: Equatable {
        let revision: Int
        let range: StatsRange
        let subject: UUID?
        let enabled: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            if let error = stats.loadError {
                WarningStrip(error, icon: "externaldrive.badge.exclamationmark")
            }
            ZStack {
                if settings.statsEnabled {
                    dashboard
                        .transition(.headerPage(reduceMotion: reduceMotion))
                } else {
                    StatsOptIn(keepsRemoved: $keepsRemovedOnStart, turnOn: turnOn)
                        .transition(.headerPage(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            SheetFooter(title: settings.statsEnabled
                        ? "Stats are kept only on this Mac."
                        : "Nothing is counted until you turn Stats on.",
                        dismiss: { dismiss() })
        }
        // Fixed, as Settings and Shortcuts are, so the sheet does not open at its
        // narrowest over a small window.
        .frame(width: 960)
        .frame(minHeight: 420, idealHeight: 780, maxHeight: 780)
        .background(Theme.background)
        .onAppear {
            keepsRemovedOnStart = settings.statsKeepsRemovedSessions
            stats.refresh(store)
        }
        .task(id: settings.statsEnabled) {
            // Sessions keep working while the sheet is open, so it reads them again now
            // and then rather than only once.
            while settings.statsEnabled, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                stats.refresh(store)
            }
        }
        .task(id: BuildKey(revision: stats.revision, range: range, subject: subject,
                           enabled: settings.statsEnabled)) {
            await rebuild()
        }
    }

    // MARK: - Header

    private var header: some View {
        SheetTitle(name: "Stats", icon: "chart.bar.xaxis") {
            if settings.statsEnabled {
                WhyButton(label: "How Stats counts", isOpen: $showsWhy) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        explanation("Agent time", "Only the stretches a turn was working. A session left open overnight is not twelve hours.")
                        explanation("Waiting on you", "From the moment an agent asked to the moment you answered. Counted from when Stats was turned on.")
                        explanation("Your reply", "From the end of a turn to your next prompt, when it came within half an hour.")
                        explanation("Cost", "What the agent reported. On a subscription, what the same use would cost on the API. Codex and Copilot report tokens only.")
                    }
                }
            }
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    private func explanation(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Typography.detail.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                controls
                if let report {
                    if report.isEmpty {
                        PaneMessage(icon: "chart.bar",
                                    title: stats.isReading ? "Reading your sessions" : "Nothing here yet",
                                    detail: stats.isReading
                                        ? "Stats fill in as each session is read."
                                        : "No agent worked and no prompt was sent in this stretch. Try a longer one.") {
                            if !stats.isReading && range != .all {
                                ActionButton(title: "Show all time", tone: .outlined) { pick(.all) }
                            }
                        }
                        .frame(height: 320)
                        .transition(.fadeIn)
                    } else {
                        StatsDashboard(report: report, range: range, subject: $subject,
                                       tint: tint(for:))
                            .transition(.fadeIn)
                    }
                } else {
                    HStack(spacing: Space.sm) {
                        RunningDot()
                        Text("Reading your sessions…")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
                settingsBlock
            }
            .padding(Space.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .motion(Motion.reveal, value: report?.isEmpty)
    }

    private var controls: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.xs) {
                ForEach(StatsRange.allCases, id: \.self) { choice in
                    ChoicePill(title: choice.title, selected: range == choice,
                               thumb: rangeTrack) { pick(choice) }
                }
            }
            Spacer(minLength: Space.md)
            if stats.isReading {
                HStack(spacing: Space.sm) {
                    RunningDot()
                    Text("Reading \(stats.total - stats.pending) of \(stats.total) sessions")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .transition(.fadeIn)
            }
            OptionMenu(value: subjectName) {
                [.item("All projects and workspaces", checked: subject == nil) { subject = nil },
                 .separator]
                + subjects.map { candidate in
                    .item(candidate.name, projectTint: tint(for: candidate),
                          checked: subject == candidate.id) { subject = candidate.id }
                }
            }
        }
        .motion(Motion.reveal, value: stats.isReading)
    }

    private func pick(_ choice: StatsRange) {
        withAnimation(reduceMotion ? nil : Motion.control) { range = choice }
    }

    // Every project and workspace that has something counted, most recent first.
    private var subjects: [StatsSubject] {
        var seen: [UUID: (subject: StatsSubject, last: Date)] = [:]
        for digest in stats.digests {
            let last = digest.spans.last?.end ?? digest.header.createdAt
            if let known = seen[digest.subject.id], known.last >= last { continue }
            seen[digest.subject.id] = (digest.subject, last)
        }
        return seen.values.sorted { $0.last > $1.last }.map(\.subject)
    }

    private var subjectName: String {
        guard let subject else { return "All projects and workspaces" }
        return subjects.first { $0.id == subject }?.name ?? "One project"
    }

    // MARK: - Settings for Stats itself

    private var settingsBlock: some View {
        ChoiceBlock("STATS SETTINGS") {
            SettingsCard {
                SettingsToggleRow(
                    "Keep stats for removed sessions",
                    detail: keptDetail,
                    isOn: Binding(get: { settings.statsKeepsRemovedSessions },
                                  set: setKeepsRemoved))
                    .padding(Space.lg)
                SettingsRowDivider()
                HStack(alignment: .center, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Turn off Stats")
                            .font(Typography.body.weight(.semibold))
                        Text("Stops counting and deletes everything Stats has kept. Your sessions are not touched.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ActionButton(title: "Turn off…", tone: .dangerOutlined, action: confirmTurnOff)
                }
                .padding(Space.lg)
            }
        }
    }

    private var keptDetail: String {
        let base = "When a session is removed, by you or by cleanup, its times, prompts and cost stay in Stats. Never its words."
        guard stats.keptCount > 0 else { return base }
        return base + " Keeping \(counted(stats.keptCount, "removed session"))."
    }

    // MARK: - Actions

    private func turnOn() {
        settings.statsKeepsRemovedSessions = keepsRemovedOnStart
        withAnimation(reduceMotion ? nil : Motion.reveal) {
            settings.statsEnabled = true
        }
        stats.turnOn()
        stats.refresh(store)
    }

    private func confirmTurnOff() {
        var rows = [Dialog.Impact.Row(title: "Everything Stats counted",
                                      detail: "Times, prompts, waits and costs it worked out")]
        if stats.keptCount > 0 {
            rows.append(Dialog.Impact.Row(title: "Stats for \(counted(stats.keptCount, "removed session"))",
                                          detail: "The sessions are gone, so these cannot be worked out again"))
        }
        rows.append(Dialog.Impact.Row(title: "Your sessions",
                                      detail: "Every conversation stays as it is", kept: true))
        dialogs.show(.impact(
            "Turn off Stats?",
            rows: rows,
            warning: "The waits Stats recorded and the stats of removed sessions cannot be restored.",
            action: "Turn off and delete") {
                withAnimation(reduceMotion ? nil : Motion.reveal) {
                    settings.statsEnabled = false
                    report = nil
                    subject = nil
                }
                stats.erase()
            })
    }

    private func setKeepsRemoved(_ keeps: Bool) {
        guard !keeps, stats.keptCount > 0 else {
            settings.statsKeepsRemovedSessions = keeps
            return
        }
        dialogs.show(.impact(
            "Stop keeping removed sessions?",
            rows: [
                Dialog.Impact.Row(title: "Stats for \(counted(stats.keptCount, "removed session"))",
                                  detail: "Their times, prompts and costs"),
                Dialog.Impact.Row(title: "Stats for sessions still in the app",
                                  detail: "Read again from the sessions themselves", kept: true)
            ],
            warning: "The removed sessions are gone, so their stats cannot be restored.",
            compact: true,
            action: "Delete their stats") {
                settings.statsKeepsRemovedSessions = false
                stats.forgetKept()
            })
    }

    private func rebuild() async {
        guard settings.statsEnabled else { return }
        let digests = stats.digests
        let events = stats.archive.events
        let since = stats.archive.enabledAt
        let range = range
        let subject = subject
        let built = await Task.detached(priority: .userInitiated) {
            StatsReport.build(digests: digests, events: events, range: range,
                              subject: subject, waitsSince: since)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : Motion.control) { report = built }
    }

    // The colour a project or workspace wears in the sidebar and on Home, so the same
    // colour means the same thing here. One that has since been removed falls back to the
    // colour its name would give it.
    private func tint(for subject: StatsSubject) -> Theme.ProjectTint {
        let avatar: SidebarAvatar?
        let fallback: Theme.ProjectTint
        if subject.isWorkspace {
            avatar = store.workspace(subject.id)?.sidebarAvatar
            fallback = Theme.workspaceTint
        } else {
            avatar = store.project(subject.id)?.sidebarAvatar
            fallback = Theme.projectTint(for: subject.name)
        }
        guard let avatar else { return fallback }
        return avatar.identityTint(iconSet: settings.sidebarIconSet,
                                   style: settings.diceBearAvatarStyle,
                                   name: subject.name, monogramTint: fallback)
    }
}

// MARK: - Asking first

// What Stats counts and where it keeps it, said before anything is counted.
private struct StatsOptIn: View {
    @Binding var keepsRemoved: Bool
    let turnOn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xxl) {
                VStack(spacing: Space.md) {
                    TitleMark(icon: "chart.bar.xaxis")
                    Text("See where your time goes")
                        .font(Typography.display)
                    Text("Stats counts how you and your agents spend your time across every project and workspace. It is off until you turn it on.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    promise("clock", "Time",
                            "How long agents work, how long they wait on you, and how long you wait on them.")
                    SettingsRowDivider()
                    promise("text.bubble", "Prompts, never their words",
                            "How many you send and when. Stats never keeps what you or the agents wrote.")
                    SettingsRowDivider()
                    promise("dollarsign.circle", "Cost and tokens",
                            "What each agent reports. On a subscription, what the same use would cost on the API.")
                    SettingsRowDivider()
                    promise("lock", "Stays on this Mac",
                            "Nothing is sent anywhere. Turning Stats off deletes everything it kept.")
                }
                .cardSurface(cornerRadius: Radius.floating)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Toggle(isOn: $keepsRemoved) {
                        Text("Keep stats for sessions I remove")
                            .font(Typography.body.weight(.semibold))
                    }
                    .toggleStyle(.appCheckbox)
                    Text("Otherwise a session's stats go when the session does. You can change this later.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ActionButton(title: "Turn on Stats", tone: .green, height: ControlHeight.xl,
                             size: Typography.Size.body, icon: "chart.bar.xaxis", action: turnOn)
            }
            .frame(maxWidth: Self.width)
            .padding(Space.xxxl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.visible)
    }

    static let width: CGFloat = 520

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: icon)
                .font(Typography.body)
                .foregroundStyle(Theme.accent)
                .frame(width: ControlHeight.xs)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typography.body.weight(.semibold))
                Text(detail)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.lg)
    }
}
