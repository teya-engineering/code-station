import Foundation

// The stretch of time Home's glance looks at. Today is a rolling day ending now, the same
// stretch the day ribbon draws, so the morning is still counted in the evening. The longer
// ranges run to the end of today and start on a day boundary, so "7 days" is this week as
// the calendar has it, today included.
enum StatsRange: String, CaseIterable, Hashable, Sendable {
    case today, week, month

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    // What a change is measured against, to end a sentence such as "18% less than ...".
    var versus: String {
        switch self {
        case .today: "yesterday"
        case .week: "the 7 days before"
        case .month: "the 30 days before"
        }
    }

    private var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        if self == .today {
            return DateInterval(start: now.addingTimeInterval(-DayRibbon.window), end: now)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    func previous(before interval: DateInterval) -> DateInterval {
        DateInterval(start: interval.start.addingTimeInterval(-interval.duration),
                            end: interval.start)
    }
}

// What a reading counts. The lens picked on Home decides what the chart's bars measure.
enum StatsLens: String, CaseIterable, Hashable, Sendable {
    case time, prompts, waiting, cost
}

// Everything Home's glance draws, worked out in one pass from the digests and events.
// It is a value with no reference back to the app, so it is built off the main actor and
// can be tested with plain dates.
struct StatsReport: Equatable, Sendable {
    struct Tile: Equatable, Sendable {
        var value: Double = 0
        var previous: Double?
        // One reading per bucket of the chart, for the line under the number.
        var spark: [Double] = []

        // The change as a fraction of what it was, or nil when there is nothing to
        // compare against.
        var change: Double? {
            guard let previous, previous > 0 else { return nil }
            return (value - previous) / previous
        }
    }

    // One subject's part of a bucket, in every lens, so changing the lens re-stacks the
    // same bars rather than building new ones.
    struct Segment: Equatable, Sendable, Identifiable {
        var subject: StatsSubject
        var seconds: TimeInterval = 0
        var prompts: Double = 0
        var waiting: TimeInterval = 0
        var cost: Double = 0
        var id: UUID { subject.id }

        func value(_ lens: StatsLens) -> Double {
            switch lens {
            case .time: seconds
            case .prompts: prompts
            case .waiting: waiting
            case .cost: cost
            }
        }
    }

    struct Bucket: Equatable, Sendable, Identifiable {
        var start: Date
        var end: Date
        var segments: [Segment]
        var id: Date { start }
        var seconds: TimeInterval { segments.reduce(0) { $0 + $1.seconds } }

        func value(_ lens: StatsLens) -> Double { segments.reduce(0) { $0 + $1.value(lens) } }
    }

    // A slot is one of the equal pieces the rolling day is cut into, the same pieces the
    // day ribbon draws.
    enum Grain: Equatable, Sendable { case slot, day }

    struct SubjectRow: Equatable, Sendable, Identifiable {
        var subject: StatsSubject
        var seconds: TimeInterval = 0
        var prompts = 0
        var cost: Double = 0
        var sessions = 0
        var id: UUID { subject.id }
    }

    struct Share: Equatable, Sendable, Identifiable {
        var name: String
        var value: Double
        var id: String { name }
    }

    struct Session: Equatable, Sendable {
        var title: String
        var subject: StatsSubject
        var seconds: TimeInterval
    }

    var interval: DateInterval
    var grain: Grain = .day

    var agentTime = Tile()
    var prompts = Tile()
    var waiting = Tile()
    var cost = Tile()

    var buckets: [Bucket] = []
    var subjects: [SubjectRow] = []

    // The back and forth.
    var averageAtOnce: Double = 0
    var peakAtOnce = 0
    var medianTurn: TimeInterval?
    var medianReply: TimeInterval?
    var questions = 0
    var permissions = 0
    var allowed = 0
    var longestWait: TimeInterval?
    // Tools the person was asked about again and again, and let through every time.
    var alwaysAllowed: [Share] = []
    var stopped = 0
    var failed = 0

    // Prompts by weekday (Monday first) and hour.
    var heat: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

    // What the agents did.
    var tools: [Share] = []
    var calls = 0
    var failedCalls = 0
    var subAgents = 0
    var added = 0
    var removed = 0
    var pullRequests = 0
    var worktreeSessions = 0
    var sessions = 0
    var dictated = 0
    var steered = 0
    var inputTokens: Double = 0
    var outputTokens: Double = 0
    var cacheReadTokens: Double = 0
    var cacheWriteTokens: Double = 0

    var agents: [Share] = []
    var models: [Share] = []

    // Records.
    var streak = 0
    var busiestDay: Share?
    var busiestDayDate: Date?
    var longestTurn: TimeInterval?
    var longestSession: Session?

    // When the waits started being counted, which is when stats were turned on.
    var waitsSince: Date?

    var isEmpty: Bool { agentTime.value == 0 && prompts.value == 0 && cost.value == 0 }

    func tile(_ lens: StatsLens) -> Tile {
        switch lens {
        case .time: agentTime
        case .prompts: prompts
        case .waiting: waiting
        case .cost: cost
        }
    }

    var cacheHitRate: Double? {
        let read = inputTokens + cacheReadTokens + cacheWriteTokens
        guard read > 0 else { return nil }
        return cacheReadTokens / read
    }

    var callErrorRate: Double? { calls > 0 ? Double(failedCalls) / Double(calls) : nil }
    var allowRate: Double? { permissions > 0 ? Double(allowed) / Double(permissions) : nil }
}

extension StatsReport {
    static let subAgentTools = ToolUse.agentTools
    // A tool asked about this often and let through every time is worth a rule.
    static let allowRuleThreshold = 5

    static func build(digests: [StatsDigest], events: [StatsEvent], range: StatsRange,
                      subject: UUID? = nil, waitsSince: Date? = nil,
                      now: Date = Date(), calendar: Calendar = .current) -> StatsReport {
        let digests = subject.map { id in digests.filter { $0.subject.id == id } } ?? digests
        let events = subject.map { id in events.filter { $0.subjectID == id } } ?? events
        let interval = range.interval(now: now, calendar: calendar)

        var report = StatsReport(interval: interval)
        report.waitsSince = waitsSince
        let (grain, buckets) = Self.buckets(for: range, interval: interval, calendar: calendar)
        report.grain = grain

        // The tiles, now and for the stretch before.
        report.agentTime.value = Self.agentSeconds(digests, in: interval)
        report.prompts.value = Double(Self.promptCount(digests, in: interval))
        report.waiting.value = Self.waitSeconds(events, in: interval)
        report.cost.value = Self.cost(digests, in: interval)
        let previous = range.previous(before: interval)
        report.agentTime.previous = Self.agentSeconds(digests, in: previous)
        report.prompts.previous = Double(Self.promptCount(digests, in: previous))
        // Waits are only recorded from when Stats was turned on, so a stretch from
        // before that has nothing to compare against rather than a wait of zero.
        if waitsSince.map({ $0 <= previous.start }) ?? true {
            report.waiting.previous = Self.waitSeconds(events, in: previous)
        }
        report.cost.previous = Self.cost(digests, in: previous)

        // The chart, split by subject in every lens, and the line under each tile.
        report.buckets = Self.split(digests: digests, events: events, into: buckets)
        report.agentTime.spark = report.buckets.map { $0.value(.time) }
        report.prompts.spark = report.buckets.map { $0.value(.prompts) }
        report.waiting.spark = report.buckets.map { $0.value(.waiting) }
        report.cost.spark = report.buckets.map { $0.value(.cost) }

        // Per subject, per agent, per model, and what the agents did.
        var rows: [StatsSubject: SubjectRow] = [:]
        var agents: [String: Double] = [:]
        var models: [String: Double] = [:]
        var tools: [String: Int] = [:]
        var turnLengths: [TimeInterval] = []
        var replies: [TimeInterval] = []
        var longest: Session?
        for digest in digests {
            let seconds = digest.spans.compactMap { $0.clipped(to: interval) }.reduce(0) { $0 + $1.seconds }
            let prompts = digest.prompts.filter { interval.contains($0.date) }
            let share = digest.share(of: interval)
            guard seconds > 0 || !prompts.isEmpty || share > 0 else { continue }

            let usage = digest.header.usage
            let cost = (usage?.costUSD ?? 0) * share
            var row = rows[digest.subject] ?? SubjectRow(subject: digest.subject)
            row.seconds += seconds
            row.prompts += prompts.count
            row.cost += cost
            row.sessions += 1
            rows[digest.subject] = row

            report.sessions += 1
            report.pullRequests += digest.header.pullRequests
            if digest.header.usesWorktree { report.worktreeSessions += 1 }
            report.dictated += prompts.count { $0.dictated }
            report.steered += prompts.count { $0.steered }
            replies += prompts.compactMap(\.replySeconds)
            if let usage {
                report.inputTokens += Double(usage.inputTokens) * share
                report.outputTokens += Double(usage.outputTokens) * share
                report.cacheReadTokens += Double(usage.cacheReadTokens) * share
                report.cacheWriteTokens += Double(usage.cacheWriteTokens) * share
                if let model = usage.model, !model.isEmpty, seconds > 0 {
                    models[model, default: 0] += seconds
                }
            }
            if seconds > 0 { agents[(usage?.latestAgent ?? digest.header.agent).title, default: 0] += seconds }

            for turn in digest.turns where interval.contains(turn.start) && turn.seconds > 0 {
                turnLengths.append(turn.seconds)
            }
            for day in digest.days where interval.contains(day.day) {
                for (tool, count) in day.tools {
                    tools[tool, default: 0] += count
                    report.calls += count
                    if Self.subAgentTools.contains(tool) { report.subAgents += count }
                }
                report.failedCalls += day.failedCalls
                report.added += day.added
                report.removed += day.removed
            }
            if seconds > (longest?.seconds ?? 0) {
                longest = Session(title: digest.header.title, subject: digest.subject, seconds: seconds)
            }
        }
        report.subjects = rows.values.sorted {
            ($0.seconds, $0.prompts, $0.cost) > ($1.seconds, $1.prompts, $1.cost)
        }
        report.agents = Self.shares(agents)
        report.models = Self.shares(models)
        report.tools = Self.shares(tools.mapValues(Double.init))
        report.medianTurn = Self.median(turnLengths)
        report.medianReply = Self.median(replies)
        report.longestTurn = turnLengths.max()
        report.longestSession = longest

        // Several sessions working at once.
        let clipped = digests.flatMap { $0.spans.compactMap { $0.clipped(to: interval) } }
        (report.averageAtOnce, report.peakAtOnce) = Self.overlap(clipped)

        // The waits, the answers and the way turns ended.
        var asked: [String: (count: Int, allowed: Int)] = [:]
        for event in events where interval.contains(event.date) {
            switch event.kind {
            case .answered:
                report.longestWait = max(report.longestWait ?? 0, event.seconds)
                if event.isQuestion == true {
                    report.questions += 1
                } else {
                    report.permissions += 1
                    if event.allowed == true { report.allowed += 1 }
                    if let tool = event.tool {
                        asked[tool, default: (0, 0)].count += 1
                        if event.allowed == true { asked[tool, default: (0, 0)].allowed += 1 }
                    }
                }
            case .turnEnded:
                if event.outcome == .stopped { report.stopped += 1 }
                if event.outcome == .failed { report.failed += 1 }
            }
        }
        report.alwaysAllowed = asked
            .filter { $0.value.count >= allowRuleThreshold && $0.value.allowed == $0.value.count }
            .map { Share(name: $0.key, value: Double($0.value.count)) }
            .sorted { ($0.value, $1.name) > ($1.value, $0.name) }

        // When the person works.
        for digest in digests {
            for prompt in digest.prompts where interval.contains(prompt.date) {
                let weekday = calendar.component(.weekday, from: prompt.date)
                let hour = calendar.component(.hour, from: prompt.date)
                report.heat[(weekday + 5) % 7][hour] += 1
            }
        }

        // Records.
        report.streak = Self.streak(digests, now: now, calendar: calendar)
        var byDay: [Date: TimeInterval] = [:]
        for span in clipped {
            for piece in Self.split(span, by: .day, calendar: calendar) {
                byDay[calendar.startOfDay(for: piece.start), default: 0] += piece.seconds
            }
        }
        if let busiest = byDay.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), busiest.value > 0 {
            report.busiestDayDate = busiest.key
            report.busiestDay = Share(name: busiest.key.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                                      value: busiest.value)
        }
        return report
    }

    // Every project and workspace that has something counted, most recent first.
    static func subjects(of digests: [StatsDigest]) -> [StatsSubject] {
        var seen: [UUID: (subject: StatsSubject, last: Date)] = [:]
        for digest in digests {
            let last = digest.spans.last?.end ?? digest.header.createdAt
            if let known = seen[digest.subject.id], known.last >= last { continue }
            seen[digest.subject.id] = (digest.subject, last)
        }
        return seen.values.sorted { $0.last > $1.last }.map(\.subject)
    }

    // MARK: - Totals

    static func agentSeconds(_ digests: [StatsDigest], in window: DateInterval) -> TimeInterval {
        digests.reduce(0) { total, digest in
            total + digest.spans.compactMap { $0.clipped(to: window) }.reduce(0) { $0 + $1.seconds }
        }
    }

    static func promptCount(_ digests: [StatsDigest], in window: DateInterval) -> Int {
        digests.reduce(0) { $0 + $1.prompts.count { window.contains($0.date) } }
    }

    static func waitSeconds(_ events: [StatsEvent], in window: DateInterval) -> TimeInterval {
        events.reduce(0) { total, event in
            guard event.kind == .answered else { return total }
            let start = max(event.date, window.start)
            let end = min(event.end, window.end)
            return total + max(0, end.timeIntervalSince(start))
        }
    }

    static func cost(_ digests: [StatsDigest], in window: DateInterval) -> Double {
        digests.reduce(0) { $0 + ($1.header.usage?.costUSD ?? 0) * $1.share(of: window) }
    }

    // MARK: - Shapes

    // As many slots as the day ribbon cuts the rolling day into, so a slot here and a bar
    // there cover the same minutes.
    static let slots = RibbonEntrance.slots

    // Each window's share of every subject, in every lens. A wait is placed by the
    // session it was asked in, since an event from before subjects were recorded has
    // only that to go on.
    static func split(digests: [StatsDigest], events: [StatsEvent],
                      into windows: [DateInterval]) -> [Bucket] {
        var subjects: [UUID: StatsSubject] = [:]
        var bySession: [UUID: StatsSubject] = [:]
        for digest in digests {
            subjects[digest.subject.id] = digest.subject
            bySession[digest.id] = digest.subject
        }
        let answered = events.compactMap { event -> (StatsEvent, StatsSubject)? in
            guard event.kind == .answered,
                  let subject = event.subjectID.flatMap({ subjects[$0] }) ?? bySession[event.sessionID]
            else { return nil }
            return (event, subject)
        }
        return windows.map { window in
            var parts: [UUID: Segment] = [:]
            func add(_ subject: StatsSubject, _ change: (inout Segment) -> Void) {
                var segment = parts[subject.id] ?? Segment(subject: subject)
                change(&segment)
                parts[subject.id] = segment
            }
            for digest in digests {
                let seconds = digest.spans.compactMap { $0.clipped(to: window) }
                    .reduce(0) { $0 + $1.seconds }
                // Half open, so a prompt on the line between two windows counts once.
                let prompts = digest.prompts.count { $0.date >= window.start && $0.date < window.end }
                let cost = (digest.header.usage?.costUSD ?? 0) * digest.share(of: window)
                guard seconds > 0 || prompts > 0 || cost > 0 else { continue }
                add(digest.subject) {
                    $0.seconds += seconds
                    $0.prompts += Double(prompts)
                    $0.cost += cost
                }
            }
            for (event, subject) in answered {
                let waited = Self.waitSeconds([event], in: window)
                if waited > 0 { add(subject) { $0.waiting += waited } }
            }
            let segments = parts.values.sorted {
                ($0.seconds, $0.subject.name) > ($1.seconds, $1.subject.name)
            }
            return Bucket(start: window.start, end: window.end, segments: segments)
        }
    }

    static func buckets(for range: StatsRange, interval: DateInterval,
                        calendar: Calendar) -> (Grain, [DateInterval]) {
        if range == .today {
            let step = interval.duration / Double(slots)
            return (.slot, (0..<slots).map { index in
                DateInterval(start: interval.start.addingTimeInterval(Double(index) * step),
                             duration: step)
            })
        }
        var start = interval.start
        var windows: [DateInterval] = []
        while start < interval.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: start), next > start else { break }
            windows.append(DateInterval(start: start, end: next))
            start = next
        }
        return (.day, windows)
    }

    static func split(_ span: StatsDigest.Span, by component: Calendar.Component,
                      calendar: Calendar) -> [StatsDigest.Span] {
        var pieces: [StatsDigest.Span] = []
        var start = span.start
        while start < span.end {
            guard let boundary = calendar.dateInterval(of: component, for: start)?.end,
                  boundary > start else { break }
            let end = min(boundary, span.end)
            pieces.append(StatsDigest.Span(start: start, end: end))
            start = end
        }
        return pieces
    }

    // How many sessions were working at once, on average while any was, and at most.
    static func overlap(_ spans: [StatsDigest.Span]) -> (average: Double, peak: Int) {
        guard !spans.isEmpty else { return (0, 0) }
        // Ends sort before starts at the same moment, so two turns that touch end to end
        // are one after the other rather than two at once.
        let edges = spans.flatMap { [($0.start, 1), ($0.end, -1)] }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var running = 0
        var peak = 0
        var busy: TimeInterval = 0
        var last = edges[0].0
        for (date, step) in edges {
            if running > 0 { busy += date.timeIntervalSince(last) }
            running += step
            peak = max(peak, running)
            last = date
        }
        let worked = spans.reduce(0) { $0 + $1.seconds }
        return (busy > 0 ? worked / busy : 0, peak)
    }

    // Days in a row with at least one prompt, counting back from today. A day not yet
    // started does not break the run: yesterday's streak still stands this morning.
    static func streak(_ digests: [StatsDigest], now: Date, calendar: Calendar) -> Int {
        let days = Set(digests.flatMap { $0.prompts.map { calendar.startOfDay(for: $0.date) } })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    static func shares(_ values: [String: Double]) -> [Share] {
        values.filter { $0.value > 0 }
            .map { Share(name: $0.key, value: $0.value) }
            .sorted { ($0.value, $1.name) > ($1.value, $0.name) }
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
