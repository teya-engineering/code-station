import Foundation

// One meaningful thing the Claude Code CLI said on its stdout stream. The CLI emits far
// more than this (rate limits, token counters, session state, thinking blocks) and adds
// new kinds over time, so anything unrecognised is dropped instead of failing the turn.
enum StreamEvent: Sendable {
    case initialized(claudeSessionID: String)
    case text(String)
    case toolUse(ToolUse)
    case toolResult(id: String, output: String, isError: Bool)
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
    static func parse(_ line: String) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init",
                  let id = object["session_id"] as? String, !id.isEmpty else { return [] }
            return [.initialized(claudeSessionID: id)]

        case "assistant":
            return contentBlocks(of: object).compactMap(assistantEvent)

        case "user":
            return contentBlocks(of: object).compactMap(toolResultEvent)

        case "result":
            // A failing turn still reports subtype "success" (a bad model, for example),
            // so is_error is the only trustworthy signal. The text of the problem is in
            // `result` for an API error and in `errors` when the CLI itself gave up.
            let isError = object["is_error"] as? Bool ?? false
            let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            let message = object["result"] as? String
                ?? (errors.isEmpty ? nil : errors.joined(separator: "\n"))
            return [.finished(isError: isError, message: message)]

        default:
            return []
        }
    }

    // MARK: - Private

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
