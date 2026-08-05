import Foundation

// One meaningful thing the Claude Code CLI said on its stdout stream. The CLI emits far
// more than this (rate limits, token counters, session state, thinking blocks) and adds
// new kinds over time, so anything unrecognised is dropped instead of failing the turn.
enum StreamEvent: Sendable {
    case initialized(claudeSessionID: String)
    case text(String)
    case toolUse(ToolUse)
    case toolResult(id: String, output: String, isError: Bool)
    // The agent asking something back. The turn is parked until it is answered.
    case permissionRequest(PermissionRequest)
    case permissionWithdrawn(id: String)
    // Where the account's usage windows stand, sent whenever they move.
    case rateLimit(RateLimit)
    // What the finished turn cost, reported alongside its result.
    case usage(TurnUsage)
    case finished(isError: Bool, message: String?)
}

extension StreamEvent {
    // A tool can return a whole file, and every result is persisted with the session, so
    // very long output is cut down before it reaches the store.
    static let maxToolOutput = 20_000

    // One JSON line can carry several content blocks, so a line maps to zero or more
    // events. This is decoded by hand rather than with Codable: the payload is deeply
    // nested, most fields are optional, shapes differ between CLI versions, and a single
    // unexpected field must never take down the stream.
    static func parse(_ line: String, projectPath: String = "") -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        switch object["type"] as? String {
        case "control_request":
            // Permission is the only thing we answer; other control requests (keep-alive,
            // MCP relays) are the CLI talking to a host we are not pretending to be.
            guard let id = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool",
                  let parsed = PermissionRequest.parse(id: id, request: request,
                                                       projectPath: projectPath) else { return [] }
            return [.permissionRequest(parsed)]

        // The agent gave up on a question of its own accord, usually because the turn was
        // interrupted. The card has to go, or it would answer a request nobody is holding.
        case "control_cancel_request":
            guard let id = object["request_id"] as? String else { return [] }
            return [.permissionWithdrawn(id: id)]

        case "system":
            guard object["subtype"] as? String == "init",
                  let id = object["session_id"] as? String, !id.isEmpty else { return [] }
            return [.initialized(claudeSessionID: id)]

        case "assistant":
            return contentBlocks(of: object).compactMap(assistantEvent)

        case "user":
            return contentBlocks(of: object).compactMap(toolResultEvent)

        case "rate_limit_event":
            guard let info = object["rate_limit_info"] as? [String: Any],
                  let kind = info["rateLimitType"] as? String,
                  let status = info["status"] as? String else { return [] }
            let resetsAt = (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            return [.rateLimit(RateLimit(kind: kind, status: status, resetsAt: resetsAt,
                                         utilization: info["utilization"] as? Double))]

        case "result":
            // A failing turn still reports subtype "success" (a bad model, for example),
            // so is_error is the only trustworthy signal. The text of the problem is in
            // `result` for an API error and in `errors` when the CLI itself gave up.
            let isError = object["is_error"] as? Bool ?? false
            let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            let message = object["result"] as? String
                ?? (errors.isEmpty ? nil : errors.joined(separator: "\n"))
            var events: [StreamEvent] = []
            if let usage = turnUsage(of: object) { events.append(.usage(usage)) }
            events.append(.finished(isError: isError, message: message))
            return events

        default:
            return []
        }
    }

    // MARK: - Private

    // The cost and token counts on a result event. `modelUsage` is keyed by the exact
    // model that ran and is the only place the context window is named, so it is read
    // for that even though the totals are easier to get from `usage`.
    private static func turnUsage(of object: [String: Any]) -> TurnUsage? {
        let counts = object["usage"] as? [String: Any]
        let perModel = object["modelUsage"] as? [String: Any]
        guard counts != nil || perModel != nil else { return nil }

        var usage = TurnUsage()
        usage.costUSD = object["total_cost_usd"] as? Double ?? 0
        usage.inputTokens = counts?["input_tokens"] as? Int ?? 0
        usage.outputTokens = counts?["output_tokens"] as? Int ?? 0
        usage.cacheReadTokens = counts?["cache_read_input_tokens"] as? Int ?? 0
        usage.cacheWriteTokens = counts?["cache_creation_input_tokens"] as? Int ?? 0

        // A turn can touch more than one model when subagents run, so the one with the
        // most output is taken as the turn's model: it is the one that did the work.
        let models = (perModel ?? [:]).compactMap { name, value -> (String, [String: Any])? in
            guard let detail = value as? [String: Any] else { return nil }
            return (name, detail)
        }
        if let main = models.max(by: { ($0.1["outputTokens"] as? Int ?? 0) < ($1.1["outputTokens"] as? Int ?? 0) }) {
            usage.model = main.1["canonicalModel"] as? String ?? main.0
            usage.contextWindow = main.1["contextWindow"] as? Int ?? 0
        }
        return usage
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return (message["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func assistantEvent(_ block: [String: Any]) -> StreamEvent? {
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "tool_use":
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return .toolUse(ToolUse(id: id, name: name, input: pretty(block["input"])))
        default:
            return nil
        }
    }

    private static func toolResultEvent(_ block: [String: Any]) -> StreamEvent? {
        guard block["type"] as? String == "tool_result",
              let id = block["tool_use_id"] as? String else { return nil }
        return .toolResult(id: id,
                           output: truncated(flatten(block["content"])),
                           isError: block["is_error"] as? Bool ?? false)
    }

    // A tool result is usually one string, but the API also allows an array of blocks,
    // which is what image and document results look like.
    private static func flatten(_ content: Any?) -> String {
        switch content {
        case let text as String:
            return text
        case let blocks as [Any]:
            return blocks.compactMap { item -> String? in
                guard let block = item as? [String: Any] else { return item as? String }
                if let text = block["text"] as? String { return text }
                guard let type = block["type"] as? String else { return nil }
                return "[\(type)]"
            }.joined(separator: "\n")
        case let value?:
            return String(describing: value)
        default:
            return ""
        }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxToolOutput else { return text }
        return String(text.prefix(maxToolOutput)) + "\n… truncated"
    }

    private static func pretty(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return value.map { String(describing: $0) } ?? "" }
        return text
    }
}

// Newline framing for the CLI's stdout. Reads off a pipe do not line up with JSON lines,
// so a partial tail is held back until the rest of it arrives. The pipe's read handler
// runs on a background queue, hence the lock.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    // Split on bytes rather than on a decoded string: a chunk boundary can land in the
    // middle of a multi-byte character, which would decode as garbage.
    func lines(from data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = pending[pending.index(after: newline)...]
        }
        // Re-base the slice so its dropped prefix is not carried around forever.
        pending = Data(pending)
        return lines
    }

    // Whatever is left when the pipe closes: the last line may have no newline.
    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return rest.isEmpty ? [] : [rest]
    }
}
