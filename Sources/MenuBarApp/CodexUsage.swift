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
    static func read(at path: String, searchPath: String) -> CodexUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        guard send(["id": 1,
                    "method": "initialize",
                    "params": ["clientInfo": ["name": "Teya", "version": "1"]]],
                   to: input.fileHandleForWriting)
        else { return nil }

        var buffer = Data()
        var requestedUsage = false
        while let message = nextMessage(from: output.fileHandleForReading, buffer: &buffer) {
            guard let id = message["id"] as? Int else { continue }
            if id == 1 {
                guard send(["id": 2, "method": "account/rateLimits/read"],
                           to: input.fileHandleForWriting)
                else { return nil }
                requestedUsage = true
            } else if id == 2, requestedUsage, let result = message["result"] as? [String: Any] {
                return CodexUsage(response: result)
            }
        }
        return nil
    }

    // MARK: - Private

    private static func send(_ object: [String: Any], to handle: FileHandle) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func nextMessage(from handle: FileHandle, buffer: inout Data) -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                return object
            }

            let chunk = handle.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }
}
