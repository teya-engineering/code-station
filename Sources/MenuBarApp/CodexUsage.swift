import Foundation

// Codex keeps its account limits behind the local app server. Reading them starts a
// short-lived server so the settings pane can show a fresh value without starting a
// coding session or sending a prompt.
struct AccountUsageWindow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetsAt: Date?

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
        var windows: [AccountUsageWindow] = []
        if let primary = window(bucket["primary"], id: "\(id)-primary", title: title) {
            windows.append(primary)
        }
        if let secondary = window(bucket["secondary"], id: "\(id)-secondary", title: "\(title) - secondary") {
            windows.append(secondary)
        }
        return windows
    }

    private static func window(_ raw: Any?, id: String, title: String) -> AccountUsageWindow? {
        guard let raw = raw as? [String: Any], let usedPercent = integer(raw["usedPercent"]) else { return nil }
        let resetsAt = integer(raw["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return AccountUsageWindow(id: id, title: title,
                                  usedPercent: min(100, max(0, usedPercent)), resetsAt: resetsAt)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

enum CodexUsageReader {
    static func read(at path: String, searchPath: String) async -> CodexUsage? {
        guard let initialize = messageData([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "Teya", "version": "1"]],
        ]), let usageRequest = messageData([
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

    private static func messageData(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}
