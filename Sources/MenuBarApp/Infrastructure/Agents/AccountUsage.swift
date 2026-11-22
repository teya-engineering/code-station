import Foundation

// How much of an agent account's limits has gone, as each agent's own `/usage` would put
// it. The limits belong to the account rather than to any session, so they are read on
// their own and held once per agent, whichever session is on screen.
struct AccountUsage: Equatable, Sendable {
    let windows: [AccountUsageWindow]
    let checkedAt: Date
}

extension AccountUsageWindow {
    static let warningPercent = 75
    static let criticalPercent = 90

    // "14:00" today, "Fri 14:00" within the week, "3 Nov" past it.
    static func resetLine(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    // How far through the window the clock is, from 0 at its start to 1 at its reset.
    // Nil when the window has no known start, or has not started yet.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let length, length > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        guard now > start else { return nil }
        return min(1, now.timeIntervalSince(start) / length)
    }

    enum Pace: Equatable {
        case steady
        // More of the limit has gone than of the time, by enough to be worth saying.
        case ahead
        case usedUp
    }

    // A few points of slack, so a window that is a hair over an even pace does not
    // raise a flag for nothing.
    static let paceSlack = 5

    func pace(now: Date = Date()) -> Pace {
        if usedPercent >= 100 { return .usedUp }
        guard let elapsed = elapsedFraction(now: now) else { return .steady }
        return usedPercent > Int((elapsed * 100).rounded()) + Self.paceSlack ? .ahead : .steady
    }

    // "resets in 3h 12m" while the reset is under a day away, then the day and time.
    func resetsLine(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let resetsAt else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        guard left > 0 else { return "resets now" }
        if left < 86_400 {
            let minutes = Int((left / 60).rounded(.up))
            let span = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            return "resets in \(span)"
        }
        return "resets \(Self.resetLine(resetsAt, now: now, calendar: calendar))"
    }
}

enum AccountUsageReading: Sendable {
    case usage(AccountUsage)
    // Why there is nothing to show, in words the tooltip can use.
    case unavailable(String)
    // The service asked not to be asked again for a while.
    case retryAfter(Duration)
}

// Where one agent keeps its account's limits. Each agent keeps them somewhere different,
// so a new agent only needs a source of its own for the rest of the app to show them.
protocol AccountUsageSource: Sendable {
    var agent: AgentKind { get }
    func read() async -> AccountUsageReading
}

// Limits are read only when someone asks for them. Each read is a call to the agent's
// service, and most of the time nobody is looking. Claude's turns still move the numbers
// on for free, since they carry the windows in the stream.
@MainActor
@Observable
final class AccountUsageMonitor {
    nonisolated static let defaultBackoff: TimeInterval = 300

    private(set) var usage: [AgentKind: AccountUsage] = [:]
    private(set) var problems: [AgentKind: String] = [:]
    private(set) var refreshing: Set<AgentKind> = []

    @ObservationIgnored private let sources: [AgentKind: any AccountUsageSource]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var holdUntil: [AgentKind: Date] = [:]

    init(sources: [any AccountUsageSource] = AccountUsageMonitor.standardSources(),
         now: @escaping () -> Date = Date.init) {
        self.sources = Dictionary(sources.map { ($0.agent, $0) }, uniquingKeysWith: { first, _ in first })
        self.now = now
    }

    nonisolated static func standardSources() -> [any AccountUsageSource] {
        [ClaudeUsageSource(), CodexUsageSource(), CopilotUsageSource()]
    }

    func supports(_ agent: AgentKind) -> Bool { sources[agent] != nil }

    func refresh(_ agent: AgentKind) async {
        guard let source = sources[agent], !refreshing.contains(agent) else { return }
        let started = now()
        if let hold = holdUntil[agent], hold > started { return }
        refreshing.insert(agent)
        let reading = await source.read()
        refreshing.remove(agent)
        switch reading {
        case .usage(let fresh):
            usage[agent] = fresh
            problems[agent] = nil
        case .unavailable(let reason):
            problems[agent] = reason
        case .retryAfter(let wait):
            holdUntil[agent] = started.addingTimeInterval(Self.seconds(wait))
            problems[agent] = "\(agent.title) asked to wait before its usage is checked again."
        }
    }

    // What a running turn reports moves the reading on between reads, without a call of
    // its own.
    func absorb(_ limit: RateLimit, for agent: AgentKind) {
        let live = Self.liveWindows(limit)
        guard !live.isEmpty else { return }
        usage[agent] = Self.merged(usage[agent], live: live, at: now())
    }

    // MARK: - Pure pieces

    // Claude Code reports the windows it read off the turn's responses. Only the windows
    // the usage endpoint also lists are taken, so both sources fill the same rows.
    nonisolated static func liveWindows(_ limit: RateLimit) -> [AccountUsageWindow] {
        var fractions: [String: RateLimit.Window] = [:]
        if let utilization = limit.utilization {
            fractions[limit.kind] = RateLimit.Window(utilization: utilization, resetsAt: limit.resetsAt)
        }
        // The headers speak for every window at once, so they win over a lone warning.
        fractions.merge(limit.windows) { _, window in window }
        return ClaudeUsage.kinds.compactMap { kind, title, shortTitle in
            fractions[kind].map {
                AccountUsageWindow(id: kind, title: title,
                                   usedPercent: min(100, max(0, Int(($0.utilization * 100).rounded()))),
                                   resetsAt: $0.resetsAt, shortTitle: shortTitle,
                                   length: ClaudeUsage.length(of: kind))
            }
        }
    }

    nonisolated static func merged(_ usage: AccountUsage?, live: [AccountUsageWindow],
                                   at date: Date) -> AccountUsage {
        var windows = usage?.windows ?? []
        for window in live {
            if let index = windows.firstIndex(where: { $0.id == window.id }) {
                windows[index] = window
            } else {
                windows.append(window)
            }
        }
        let order = ClaudeUsage.kinds.map(\.kind)
        windows.sort {
            (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count)
        }
        return AccountUsage(windows: windows, checkedAt: date)
    }

    nonisolated private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
