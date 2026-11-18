import SwiftUI

// The readings themselves, drawn from one report. Every section reads from the same
// value, so a range or a filter changes them all in one movement.
struct StatsDashboard: View {
    let report: StatsReport
    let range: StatsRange
    @Binding var subject: UUID?
    let tint: (StatsSubject) -> Theme.ProjectTint

    private static let columns = [GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading),
                                  GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading)]
    private static let factColumns = [GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading),
                                      GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading),
                                      GridItem(.flexible(), spacing: Space.lg, alignment: .topLeading)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            tiles
            timeChart
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
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            StatTile(title: "AGENT TIME", value: StatsFormat.time(report.agentTime.value),
                     reading: report.agentTime.value, change: report.agentTime.change,
                     comparison: range.comparison, spark: report.agentTime.spark)
            StatTile(title: "PROMPTS", value: StatsFormat.count(Int(report.prompts.value)),
                     reading: report.prompts.value, change: report.prompts.change,
                     comparison: range.comparison, spark: report.prompts.spark)
            StatTile(title: "WAITING ON YOU", value: StatsFormat.time(report.waiting.value),
                     reading: report.waiting.value, change: report.waiting.change,
                     lowerIsBetter: true, comparison: range.comparison,
                     spark: report.waiting.spark, tint: Theme.attention)
            StatTile(title: "COST", value: StatsFormat.money(report.cost.value),
                     reading: report.cost.value, change: report.cost.change,
                     lowerIsBetter: true, comparison: range.comparison,
                     spark: report.cost.spark, tint: Theme.secret)
        }
    }

    // MARK: - Where the time went

    private var timeChart: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule(title: "WHERE THE TIME WENT") {
                Text(StatsFormat.time(report.agentTime.value) + " of agent work")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: Space.md) {
                StackedBarChart(bars: bars, labelled: labelled, format: StatsFormat.axis)
                legend
            }
            .padding(Space.card)
            .cardSurface()
        }
    }

    private var bars: [StackedBarChart.Bar] {
        report.buckets.map { bucket in
            StackedBarChart.Bar(
                id: label(bucket.start),
                title: title(bucket.start),
                pieces: bucket.segments.map { segment in
                    StackedBarChart.Piece(id: segment.subject.id.uuidString,
                                          name: segment.subject.name,
                                          value: segment.seconds,
                                          tint: tint(segment.subject).colour)
                })
        }
    }

    // Every bar is named under a week; a day or a month names one bar in a few.
    private var labelled: [String] {
        let every = switch report.grain {
        case .hour: 3
        case .day: report.buckets.count > 10 ? 5 : 1
        case .week: 4
        }
        return report.buckets.enumerated()
            .filter { $0.offset % every == 0 }
            .map { label($0.element.start) }
    }

    private func label(_ date: Date) -> String {
        switch report.grain {
        case .hour: date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))
        case .day where report.buckets.count <= 10: date.formatted(.dateTime.weekday(.abbreviated).day())
        case .day, .week: date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private func title(_ date: Date) -> String {
        switch report.grain {
        case .hour: date.formatted(.dateTime.hour().minute())
        case .day: date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        case .week: "Week of " + date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var legend: some View {
        let shown = report.subjects.filter { $0.seconds > 0 }
        return HStack(spacing: Space.lg) {
            ForEach(shown.prefix(5)) { row in
                LegendItem(name: row.subject.name, tint: tint(row.subject),
                           value: StatsFormat.time(row.seconds))
            }
            if shown.count > 5 {
                Text("+\(shown.count - 5) more")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Projects and workspaces

    private var subjects: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule(title: "PROJECTS & WORKSPACES") {
                if subject != nil {
                    InlineLink(title: "Show all", size: Typography.Size.caption) { choose(nil) }
                        .fixedSize()
                        .transition(.fadeIn)
                }
            }
            let rows = Array(report.subjects.prefix(8))
            let scale = rows.map(\.seconds).max() ?? 0
            VStack(spacing: Space.xxs) {
                ForEach(rows) { row in
                    Button { choose(subject == row.subject.id ? nil : row.subject.id) } label: {
                        ShareBarRow(name: row.subject.name, dot: tint(row.subject),
                                    value: row.seconds, scale: scale,
                                    reading: StatsFormat.time(row.seconds),
                                    detail: "\(StatsFormat.count(row.prompts)) · \(StatsFormat.money(row.cost))")
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)
                            .background {
                                if subject == row.subject.id {
                                    RoundedRectangle(cornerRadius: Radius.control).fill(Theme.accent.opacity(0.1))
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
            .padding(.vertical, Space.sm)
            .cardSurface()
            Text("Time · prompts · cost")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .motion(Motion.control, value: subject)
    }

    private func choose(_ id: UUID?) {
        subject = id
    }

    // MARK: - The back and forth

    private var backAndForth: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("THE BACK AND FORTH")
            VStack(alignment: .leading, spacing: Space.lg) {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Space.lg) {
                    StatFact(label: "Agents at once",
                             value: report.peakAtOnce > 0
                                ? "\(StatsFormat.average(report.averageAtOnce)) avg · \(report.peakAtOnce) peak"
                                : "–",
                             detail: "While any was working")
                    StatFact(label: "Median turn", value: StatsFormat.short(report.medianTurn),
                             detail: "How long you wait for a reply")
                    StatFact(label: "Your reply", value: StatsFormat.short(report.medianReply),
                             detail: "From a reply to your next prompt")
                    StatFact(label: "Longest wait on you", value: StatsFormat.short(report.longestWait),
                             detail: "\(counted(report.questions, "question")) asked")
                    StatFact(label: "Permissions",
                             value: report.permissions > 0
                                ? "\(StatsFormat.count(report.permissions)) · \(StatsFormat.percent(report.allowRate)) allowed"
                                : "–",
                             detail: "Tools the agents asked to use")
                    StatFact(label: "Turns cut short",
                             value: "\(report.stopped) stopped · \(report.failed) failed",
                             tint: report.failed > 0 ? Theme.attentionText : nil)
                }
                if let rule = report.alwaysAllowed.first {
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "lightbulb")
                            .font(Typography.detail)
                            .foregroundStyle(Theme.attentionText)
                        Text("You let **\(rule.name)** through all \(Int(rule.value)) times you were asked. A permission rule for it would save you the wait.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.attention.opacity(0.1)))
                    .transition(.fadeIn)
                }
                if let since = report.waitsSince, since > report.interval.start {
                    Text("Waits and answers are counted from \(since.formatted(date: .abbreviated, time: .omitted)), when Stats was turned on.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.card)
            .cardSurface()
        }
    }

    // MARK: - When you work

    private var whenYouWork: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("WHEN YOU WORK")
            HeatGrid(rows: Self.weekdays, values: report.heat,
                     columnLabels: [0: "00", 6: "06", 12: "12", 18: "18"]) { row, column, value in
                let hours = String(format: "%02d:00–%02d:00", column, (column + 1) % 24)
                return "\(Self.weekdays[row]) \(hours) · \(counted(value, "prompt"))"
            }
            .padding(Space.card)
            .cardSurface()
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
            VStack(alignment: .leading, spacing: Space.md) {
                shares(report.agents, tint: Theme.accent)
                if !report.models.isEmpty {
                    SettingsRowDivider().padding(.horizontal, -Space.lg)
                    shares(Array(report.models.prefix(4)), tint: Theme.plan)
                }
                if report.agents.isEmpty {
                    Text("No agent worked in this stretch.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Space.card)
            .cardSurface()
        }
    }

    private func shares(_ shares: [StatsReport.Share], tint: Color) -> some View {
        let total = shares.reduce(0) { $0 + $1.value }
        let scale = shares.map(\.value).max() ?? 0
        return VStack(spacing: Space.sm) {
            ForEach(shares) { share in
                ShareBarRow(name: share.name, tint: tint, value: share.value, scale: scale,
                            reading: StatsFormat.time(share.value),
                            detail: StatsFormat.percent(total > 0 ? share.value / total : nil))
            }
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
            HStack(alignment: .top, spacing: Space.xxl) {
                let tools = Array(report.tools.prefix(6))
                let scale = tools.map(\.value).max() ?? 0
                VStack(spacing: Space.sm) {
                    ForEach(tools) { tool in
                        ShareBarRow(name: tool.name, tint: Theme.accent, value: tool.value, scale: scale,
                                    reading: StatsFormat.count(Int(tool.value)),
                                    detail: StatsFormat.percent(report.calls > 0 ? tool.value / Double(report.calls) : nil))
                    }
                    if tools.isEmpty {
                        Text("No tool calls in this stretch.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                LazyVGrid(columns: Self.factColumns, alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Lines changed")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        DiffPair(added: report.added, removed: report.removed, size: Typography.Size.body)
                    }
                    StatFact(label: "Pull requests", value: StatsFormat.count(report.pullRequests))
                    StatFact(label: "Sub-agents", value: StatsFormat.count(report.subAgents))
                    StatFact(label: "Tool errors", value: StatsFormat.percent(report.callErrorRate),
                             detail: "\(StatsFormat.count(report.failedCalls)) failed")
                    StatFact(label: "Tokens",
                             value: StatsFormat.tokens(report.inputTokens + report.outputTokens
                                                       + report.cacheReadTokens + report.cacheWriteTokens),
                             detail: "\(StatsFormat.tokens(report.outputTokens)) written")
                    StatFact(label: "Cache hits", value: StatsFormat.percent(report.cacheHitRate),
                             detail: "Of what was read in")
                    StatFact(label: "Sessions", value: StatsFormat.count(report.sessions),
                             detail: "\(report.worktreeSessions) in a worktree")
                    StatFact(label: "Spoken prompts", value: StatsFormat.count(report.dictated))
                    StatFact(label: "Sent mid-turn", value: StatsFormat.count(report.steered))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(Space.card)
            .cardSurface()
        }
    }

    // MARK: - Records

    private var records: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule("RECORDS")
            HStack(alignment: .top, spacing: Space.lg) {
                StatFact(label: "Streak",
                         value: report.streak > 0 ? counted(report.streak, "day") : "–",
                         detail: "Days in a row with a prompt")
                StatFact(label: "Busiest day", value: report.busiestDay?.name ?? "–",
                         detail: report.busiestDay.map { StatsFormat.time($0.value) + " of agent work" })
                StatFact(label: "Longest turn", value: StatsFormat.short(report.longestTurn))
                StatFact(label: "Longest session",
                         value: report.longestSession.map { StatsFormat.time($0.seconds) } ?? "–",
                         detail: report.longestSession.map { "\($0.title) · \($0.subject.name)" })
            }
            .padding(Space.card)
            .cardSurface()
        }
    }
}
