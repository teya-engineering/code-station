import Foundation

// Codex keeps its account limits behind the local app server. Reading them starts a
// short-lived server so the settings pane can show a fresh value without starting a
// coding session or sending a prompt.
struct AccountUsageWindow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetsAt: Date?
    // What the window is called where a line is short, like a hint's row.
    var shortTitle: String? = nil
    // How long the window runs from start to reset. Left out where the source does not
    // say, since a guessed start would put the pace mark in the wrong place.
    var length: TimeInterval? = nil

    var usedFraction: Double { Double(usedPercent) / 100 }
}

struct CodexUsage: Equatable, Sendable {

    let windows: [AccountUsageWindow]
    let checkedAt: Date

    init?(response: [String: Any], checkedAt: Date = Date()) {
        let buckets: [(String, [String: Any])]
        if let byID = response["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            buckets = byID.compactMap { id, value in
                (value as? [String: Any]).map { (id, $0) }
            }
        } else if let limit = response["rateLimits"] as? [String: Any] {
            let id = limit["limitId"] as? String ?? "codex"
            buckets = [(id, limit)]
        } else {
            return nil
        }

        let windows = buckets.sorted { $0.0 < $1.0 }.flatMap { id, bucket in
            Self.windows(in: bucket, id: id)
        }
        guard !windows.isEmpty else { return nil }
        self.windows = windows
        self.checkedAt = checkedAt
    }

    // MARK: - Private

    private static func windows(in bucket: [String: Any], id: String) -> [AccountUsageWindow] {
        let title = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (id == "codex" ? "Current limit" : id.replacingOccurrences(of: "_", with: " ").capitalized)
        // A hint's row has room for a word or two. The default limit goes by the length of
        // its window when Codex gives it, and another model's limit leads with its name.
        let isDefault = id == "codex"
        var windows: [AccountUsageWindow] = []
        if let primary = window(bucket["primary"], id: "\(id)-primary", title: title,
                                shortTitle: isDefault ? nil : title, fallback: "Limit") {
            windows.append(primary)
        }
        if let secondary = window(bucket["secondary"], id: "\(id)-secondary", title: "\(title) - secondary",
                                  shortTitle: isDefault ? nil : title, fallback: "Second limit") {
            windows.append(secondary)
        }
        return windows
    }

    private static func window(_ raw: Any?, id: String, title: String,
                               shortTitle name: String?, fallback: String) -> AccountUsageWindow? {
        guard let raw = raw as? [String: Any], let usedPercent = integer(raw["usedPercent"]) else { return nil }
        let resetsAt = integer(raw["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let duration = integer(raw["windowDurationMins"]).flatMap { Self.span(minutes: $0) }
        let shortTitle = switch (name, duration) {
        case (let name?, let duration?): "\(name) · \(duration)"
        case (let name?, nil): name
        case (nil, let duration?): duration
        case (nil, nil): fallback
        }
        return AccountUsageWindow(id: id, title: title,
                                  usedPercent: min(100, max(0, usedPercent)), resetsAt: resetsAt,
                                  shortTitle: shortTitle,
                                  length: integer(raw["windowDurationMins"]).flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil })
    }

    // How long a window runs, in a word: "5h", "Week".
    static func span(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        if minutes == 7 * 1_440 { return "Week" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

enum CodexUsageReader {
    static func read(at path: String, searchPath: String) async -> CodexUsage? {
        let framer = AgentMessageFramer(format: .jsonLines)
        guard let initialize = framer.frame([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "Teya", "version": "1"]],
        ]), let usageRequest = framer.frame([
            "id": 2,
            "method": "account/rateLimits/read",
        ]) else { return nil }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath

        guard let output = try? await CommandRunner.run(
            executable: path,
            arguments: ["app-server", "--stdio"],
            environment: environment,
            input: initialize,
            outputLineHandler: { line in
                guard let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = message["id"] as? Int else { return .none }
                if id == 1 { return .write(usageRequest) }
                return id == 2 ? .finishProcess : .none
            },
            timeout: .seconds(10),
            outputByteLimit: 262_144
        ) else { return nil }

        for line in output.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (message["id"] as? Int) == 2,
                  let result = message["result"] as? [String: Any] else { continue }
            return CodexUsage(response: result)
        }
        return nil
    }
}
