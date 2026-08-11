import Foundation

struct CodexContextSnapshot: Equatable, Sendable {
    let inputTokens: Int
    let contextWindow: Int
    let model: String?
}

// `codex exec --json` reports how much a whole turn consumed, but that total can contain
// several model calls and is not the size of the current prompt. Codex writes the last
// call and its effective window to the conversation rollout, which is the same state its
// own clients use when they resume a thread.
actor CodexContextReader {
    private let roots: [URL]
    private var files: [String: URL] = [:]

    init(codexHome: URL = CodexContextReader.defaultHome()) {
        roots = [codexHome.appendingPathComponent("sessions", isDirectory: true),
                 codexHome.appendingPathComponent("archived_sessions", isDirectory: true)]
    }

    func read(threadID: String) async -> CodexContextSnapshot? {
        guard !threadID.isEmpty else { return nil }

        // The completion event and rollout write come from the same process, but the
        // filesystem can become visible a beat later on a newly created conversation.
        for attempt in 0..<3 {
            if let file = rollout(for: threadID), let snapshot = snapshot(in: file) {
                return snapshot
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(50)) }
        }
        return nil
    }

    nonisolated static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func rollout(for threadID: String) -> URL? {
        if let file = files[threadID], FileManager.default.fileExists(atPath: file.path) {
            return file
        }

        let suffix = "-\(threadID).jsonl"
        for root in roots {
            guard let entries = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in entries where file.lastPathComponent.hasSuffix(suffix) {
                files[threadID] = file
                return file
            }
        }
        return nil
    }

    private func snapshot(in file: URL) -> CodexContextSnapshot? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }

        var inputTokens: Int?
        var contextWindow: Int?
        var model: String?
        var foundModel = false
        var lineEnd = data.endIndex

        while lineEnd > data.startIndex, inputTokens == nil || contextWindow == nil || !foundModel {
            if data[data.index(before: lineEnd)] == UInt8(ascii: "\n") {
                lineEnd = data.index(before: lineEnd)
                continue
            }

            let prefix = data[data.startIndex..<lineEnd]
            let newline = prefix.lastIndex(of: UInt8(ascii: "\n"))
            let lineStart = newline.map { data.index(after: $0) } ?? data.startIndex
            if let object = Self.object(from: data[lineStart..<lineEnd]) {
                if inputTokens == nil || contextWindow == nil,
                   object["type"] as? String == "event_msg",
                   let payload = object["payload"] as? [String: Any],
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any]
                        ?? info["lastTokenUsage"] as? [String: Any] {
                    inputTokens = Self.integer(last["input_tokens"] ?? last["inputTokens"])
                    contextWindow = Self.integer(
                        info["model_context_window"] ?? info["modelContextWindow"])
                }
                if !foundModel, object["type"] as? String == "turn_context",
                   let payload = object["payload"] as? [String: Any] {
                    model = payload["model"] as? String
                    foundModel = true
                }
            }
            lineEnd = newline ?? data.startIndex
        }

        guard let inputTokens, inputTokens > 0,
              let contextWindow, contextWindow > 0 else { return nil }
        return CodexContextSnapshot(inputTokens: inputTokens,
                                    contextWindow: contextWindow,
                                    model: model)
    }

    private static func object(from line: Data.SubSequence) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}
