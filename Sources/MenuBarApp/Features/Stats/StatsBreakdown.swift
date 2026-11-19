import SwiftUI

// Everything behind Home's glance, opened in place under its card. Every section reads
// from the same report, so a stretch or a filter changes them all in one movement.
struct StatsBreakdown: View {
    let report: StatsReport
    @Binding var subject: UUID?
    let tint: (StatsSubject) -> Theme.ProjectTint

    private static let two = [GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading),
                              GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading)]
    private static let three = two + [GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading)]

    // One colour per kind of reading, kept wherever that reading appears.
    enum Ink {
        static let time = Theme.accent
        static let prompts = Theme.plan
        static let waiting = Theme.attention
        static let cost = Theme.secret
        // Neighbours always differ in hue: the two golds never sit side by side.
        static let shares = [Theme.accent, Theme.plan, Theme.secret, Theme.showcase, Theme.attention,
                             Theme.workspaceTint.colour]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack(alignment: .top, spacing: Space.xxl) {
                subjects.frame(maxWidth: .infinity, alignment: .topLeading)
                backAndForth.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(alignment: .top, spacing: Space.xxl) {
                whenYouWork.frame(maxWidth: .infinity, alignment: .topLeading)
                agentsAndModels.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            whatTheAgentsDid
            records
            Label("Stats are kept only on this Mac. Turning Stats off in Settings deletes everything it kept.",
                  systemImage: "lock.fill")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Projects and workspaces

    private var subjects: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule(title: "PROJECTS & WORKSPACES") {
                if subject != nil {
                    InlineLink(title: "Show all", size: Typography.Size.caption) { subject = nil }
                        .fixedSize()
                        .transition(.fadeIn)
                }
            }
            let rows = Array(report.subjects.prefix(8))
            let scale = rows.map(\.seconds).max() ?? 0
            let total = max(report.agentTime.value, 1)
            VStack(spacing: Space.xxs) {
                ForEach(rows) { row in
                    Button { subject = subject == row.subject.id ? nil : row.subject.id } label: {
                        ShareBarRow(name: row.subject.name, dot: tint(row.subject), tile: true,
                                    value: row.seconds, scale: scale,
                                    reading: StatsFormat.time(row.seconds),
                                    detail: "\(StatsFormat.percent(row.seconds / total)) · \(StatsFormat.money(row.cost))")
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)
                            .background {
                                if subject == row.subject.id {
                                    RoundedRectangle(cornerRadius: Radius.control)
                                        .fill(tint(row.subject).fill)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
                    }
                    .buttonStyle(.plain)
                    .hoverFill()
                    .appTooltip(subject == row.subject.id ? "Show every project" : "Show only \(row.subject.name)")
                }
                if report.subjects.count > rows.count {
                    Text("and \(counted(report.subjects.count - rows.count, "more"))")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.md)
                }
            }
            .padding(Space.sm)
            .cardSurface(cornerRadius: Radius.floating)
            Text("Time · share of it · cost. Click one to see only its numbers.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .motion(Motion.control, value: subject)
    }

    // MARK: - The back and forth

    private var backAndForth: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("THE BACK AND FORTH")
            VStack(alignment: .leading, spacing: Space.lg) {
                LazyVGrid(columns: Self.two, alignment: .leading, spacing: Space.lg) {
                    StatFact(label: "Median turn", value: StatsFormat.short(report.medianTurn),
                             detail: "How long you wait for a reply", tint: Ink.time, icon: "timer")
                    StatFact(label: "Your reply", value: StatsFormat.short(report.medianReply),
                             detail: "From a reply to your next prompt", tint: Ink.prompts,
                             icon: "arrowshape.turn.up.left.fill")
                    StatFact(label: "Longest wait on you", value: StatsFormat.short(report.longestWait),
                             detail: "\(counted(report.questions, "question")) asked", tint: Ink.waiting,
                             icon: "hourglass")
                    StatFact(label: "Permissions",
                             value: report.permissions > 0
                                ? "\(StatsFormat.count(report.permissions)) · \(StatsFormat.percent(report.allowRate)) allowed"
                                : "–",
                             detail: "Tools the agents asked to use", tint: Theme.dotOnText,
                             icon: "checkmark.shield.fill")
                    StatFact(label: "Agents at once",
                             value: report.peakAtOnce > 0
                                ? "\(StatsFormat.average(report.averageAtOnce)) avg · \(report.peakAtOnce) peak"
                                : "–",
                             detail: "While any was working", tint: Theme.showcase,
                             icon: "square.stack.3d.up.fill")
                    StatFact(label: "Turns cut short",
                             value: "\(report.stopped) stopped · \(report.failed) failed",
                             tint: report.failed > 0 ? Theme.deletion : Theme.secondaryText,
                             icon: "stop.circle.fill")
                }
                if let rule = report.alwaysAllowed.first {
                    HStack(alignment: .top, spacing: Space.md) {
                        IconBadge(icon: "lightbulb.fill", tint: Ink.waiting)
                        Text("You let **\(rule.name)** through all \(Int(rule.value)) times you were asked. A permission rule for it would save you the wait.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .washSurface(tint: Ink.waiting)
                    .transition(.fadeIn)
                }
                if let since = report.waitsSince, since > report.interval.start {
                    Text("Waits and answers are counted from \(since.formatted(date: .abbreviated, time: .omitted)), when Stats was turned on.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.lg)
            .cardSurface(cornerRadius: Radius.floating)
        }
    }

    // MARK: - When you work

    private var whenYouWork: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("WHEN YOU WORK")
            HeatGrid(rows: Self.weekdays, values: report.heat,
                     columnLabels: [0: "00", 6: "06", 12: "12", 18: "18"], tint: Ink.prompts) { row, column, value in
                let hours = String(format: "%02d:00–%02d:00", column, (column + 1) % 24)
                return "\(Self.weekdays[row]) \(hours) · \(counted(value, "prompt"))"
            }
            .padding(Space.lg)
            .cardSurface(cornerRadius: Radius.floating)
        }
    }

    private static let weekdays: [String] = {
        var calendar = Calendar.current
        calendar.locale = .current
        let symbols = calendar.shortWeekdaySymbols
        // Monday first, the way the report counts them.
        return Array(symbols[1...] + symbols[..<1])
    }()

    // MARK: - Agents and models

    private var agentsAndModels: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("AGENTS & MODELS")
            VStack(alignment: .leading, spacing: Space.lg) {
                if report.agents.isEmpty {
                    Text("No agent worked in this stretch.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                } else {
                    ShareDonut(parts: parts(report.agents, palette: Ink.shares), format: StatsFormat.time)
                    if !report.models.isEmpty {
                        SettingsRowDivider().padding(.horizontal, -Space.lg)
                        ShareDonut(parts: parts(Array(report.models.prefix(4)),
                                                palette: [Theme.plan, Theme.showcase, Theme.secret, Theme.attention]),
                                   format: StatsFormat.time)
                    }
                }
            }
            .padding(Space.lg)
            .cardSurface(cornerRadius: Radius.floating)
        }
    }

    private func parts(_ shares: [StatsReport.Share], palette: [Color]) -> [ShareStrip.Part] {
        shares.enumerated().map { index, share in
            ShareStrip.Part(name: share.name, value: share.value, tint: palette[index % palette.count])
        }
    }

    // MARK: - What the agents did

    private var whatTheAgentsDid: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule(title: "WHAT THE AGENTS DID") {
                Text(counted(report.calls, "tool call"))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: Space.xl) {
                if report.tools.isEmpty {
                    Text("No tool calls in this stretch.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                } else {
                    ShareStrip(parts: toolParts, format: { StatsFormat.count(Int($0)) })
                }
                LazyVGrid(columns: Self.three, alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(alignment: .top, spacing: Space.md) {
                            IconBadge(icon: "plusminus", tint: Theme.dotOnText)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text("Lines changed")
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                                DiffPair(added: report.added, removed: report.removed, size: Typography.Size.body)
                            }
                        }
                    }
                    StatFact(label: "Pull requests", value: StatsFormat.count(report.pullRequests),
                             tint: Theme.showcase, icon: "arrow.triangle.pull")
                    StatFact(label: "Sub-agents", value: StatsFormat.count(report.subAgents),
                             tint: Ink.prompts, icon: "person.2.fill")
                    StatFact(label: "Tool errors", value: StatsFormat.percent(report.callErrorRate),
                             detail: "\(StatsFormat.count(report.failedCalls)) failed", tint: Theme.deletion,
                             icon: "exclamationmark.triangle.fill")
                    StatFact(label: "Tokens",
                             value: StatsFormat.tokens(report.inputTokens + report.outputTokens
                                                       + report.cacheReadTokens + report.cacheWriteTokens),
                             detail: "\(StatsFormat.tokens(report.outputTokens)) written", tint: Ink.cost,
                             icon: "circle.hexagongrid.fill")
                    StatFact(label: "Cache hits", value: StatsFormat.percent(report.cacheHitRate),
                             detail: "Of what was read in", tint: Ink.time, icon: "bolt.fill")
                    StatFact(label: "Sessions", value: StatsFormat.count(report.sessions),
                             detail: "\(report.worktreeSessions) in a worktree", tint: Ink.time,
                             icon: "bubble.left.and.bubble.right.fill")
                    StatFact(label: "Spoken prompts", value: StatsFormat.count(report.dictated),
                             tint: Ink.prompts, icon: "mic.fill")
                    StatFact(label: "Sent mid-turn", value: StatsFormat.count(report.steered),
                             tint: Ink.waiting, icon: "arrow.turn.down.right")
                }
            }
            .padding(Space.lg)
            .cardSurface(cornerRadius: Radius.floating)
        }
    }

    // The busiest tools by name, and the rest as one part, so the bar stays readable.
    private var toolParts: [ShareStrip.Part] {
        let shown = Array(report.tools.prefix(5))
        var parts = parts(shown, palette: Ink.shares)
        let rest = report.tools.dropFirst(5).reduce(0) { $0 + $1.value }
        if rest > 0 { parts.append(ShareStrip.Part(name: "Other", value: rest, tint: Theme.dotOff)) }
        return parts
    }

    // MARK: - Records

    private var records: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("RECORDS")
            LazyVGrid(columns: Self.two, alignment: .leading, spacing: Space.lg) {
                RecordBadge(icon: "flame.fill", label: "STREAK",
                            value: report.streak > 0 ? counted(report.streak, "day") : "–",
                            detail: "Days in a row with a prompt", tint: Ink.waiting)
                RecordBadge(icon: "calendar", label: "BUSIEST DAY", value: report.busiestDay?.name ?? "–",
                            detail: report.busiestDay.map { StatsFormat.time($0.value) + " of agent work" },
                            tint: Ink.time)
                RecordBadge(icon: "timer", label: "LONGEST TURN", value: StatsFormat.short(report.longestTurn),
                            detail: "One reply, start to finish", tint: Ink.prompts)
                RecordBadge(icon: "trophy.fill", label: "LONGEST SESSION",
                            value: report.longestSession.map { StatsFormat.time($0.seconds) } ?? "–",
                            detail: report.longestSession.map { "\($0.title) · \($0.subject.name)" },
                            tint: Ink.cost)
            }
        }
    }
}
