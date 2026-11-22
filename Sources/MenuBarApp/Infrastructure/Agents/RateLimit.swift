import Foundation

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
    // Every window the account has, by kind, as the response headers of the turn read
    // them. These come with each turn whatever the status, so they are what keeps a
    // reading current between threshold warnings.
    var windows: [String: Window] = [:]

    struct Window: Equatable, Sendable {
        // A fraction of the window that has been used.
        var utilization: Double
        var resetsAt: Date?
    }

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
