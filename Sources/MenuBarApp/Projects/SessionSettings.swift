import Foundation

// What a session runs Claude Code with, on top of the prompt itself. These are the same
// choices the CLI offers behind /model, /effort and its permission modes.
//
// The same type holds both layers. As a session's settings, nil means "no override" and
// the app default takes over; as the app defaults, nil means the flag is left off
// entirely and Claude Code's own configuration decides.
struct SessionSettings: Codable, Equatable {
    var model: String?
    var effort: String?
    var permissionMode: String?

    // A session that has chosen nothing runs exactly as the app settings say.
    var overridesAnything: Bool {
        model != nil || effort != nil || permissionMode != nil
    }
}

// The model aliases the CLI takes. Full names ("claude-opus-5") work too, but an alias
// always points at the newest of that family, which is what a picker should do.
enum ModelChoice {
    static let all: [(id: String?, title: String, detail: String)] = [
        (nil, "Default", "Whatever Claude Code is set to use."),
        ("opus", "Opus", "The strongest reasoning, and the slowest."),
        ("sonnet", "Sonnet", "The everyday balance of speed and depth."),
        ("haiku", "Haiku", "The fastest and cheapest; best for small, mechanical work."),
        ("fable", "Fable", "Tuned for writing and long-form prose."),
    ]

    static func title(of id: String?) -> String {
        all.first { $0.id == id }?.title ?? id ?? "Default"
    }

    // How the app-wide choice reads on the row that says a session is following it.
    static func summary(of id: String?) -> String {
        guard let id, !id.isEmpty else { return "Whatever Claude Code is set to use" }
        return title(of: id)
    }
}

// How long the model spends thinking before it answers. More effort costs more tokens
// and more time, so it is the first thing to turn down when a limit is close.
enum EffortChoice {
    static let all: [(id: String?, title: String)] = [
        (nil, "Default"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra high"),
        ("max", "Max"),
    ]

    static func summary(of id: String?) -> String {
        guard let id, !id.isEmpty else { return "Whatever Claude Code is set to use" }
        return all.first { $0.id == id }?.title ?? id
    }
}

// What one finished turn cost. Read off the CLI's result event, which reports the whole
// turn including every tool call inside it.
struct TurnUsage: Equatable, Sendable {
    var costUSD: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    // What the model is told to use for this model, when it says.
    var contextWindow = 0
    var model: String?

    // Everything the model read this turn, which is roughly where the next turn starts
    // from. Cached tokens count: they are still in the window, they were just cheaper.
    var contextTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
}

// Everything the session has spent so far. Persisted with the conversation, so the
// numbers survive a restart the way the transcript does.
struct SessionUsage: Codable, Equatable {
    var costUSD: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var turns = 0
    // The last turn's context rather than a running total: it is what the next turn
    // starts from, so it is the number that says how much room is left.
    var contextTokens = 0
    var contextWindow = 0
    var model: String?

    mutating func add(_ turn: TurnUsage) {
        costUSD += turn.costUSD
        inputTokens += turn.inputTokens
        outputTokens += turn.outputTokens
        cacheReadTokens += turn.cacheReadTokens
        cacheWriteTokens += turn.cacheWriteTokens
        turns += 1
        contextTokens = turn.contextTokens
        if turn.contextWindow > 0 { contextWindow = turn.contextWindow }
        if let model = turn.model { self.model = model }
    }

    var contextFraction: Double? {
        guard contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

// One of the account's usage windows, as the CLI reports it while a turn runs. This is
// what `/usage` shows: it belongs to the account rather than to any one session, and it
// is only ever as fresh as the last turn that ran.
struct RateLimit: Equatable, Sendable {
    var kind: String
    var status: String
    var resetsAt: Date?
    // A fraction of the window that has been used. The CLI only sends it once a window
    // is far enough along to be worth warning about, so it is usually missing.
    var utilization: Double?

    var title: String {
        switch kind {
        case "five_hour": "Current session limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        case "seven_day_overage_included", "overage": "Extra usage"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var isBlocked: Bool { status == "rejected" }
    var isWarning: Bool { status == "allowed_warning" }
}

// Token counts run to seven digits, which nothing on screen has room for.
func formattedTokens(_ count: Int) -> String {
    switch count {
    case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
    case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
    default: "\(count)"
    }
}
