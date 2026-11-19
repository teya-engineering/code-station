import Foundation

// What Kiro said on its ACP stream, folded onto the events the rest of the app already
// reads. Kiro speaks the Agent Client Protocol: every change to the session arrives as a
// `session/update` notification, the text in small chunks, and every tool as a call
// followed by updates that carry its result. The app draws text a block at a time, so
// chunks are held until something else arrives and then handed on as one block.
//
// A resumed session opens by replaying its whole history, each update marked as a
// replay. The app already holds that conversation, so a replay is dropped.
final class KiroStream: @unchecked Sendable {
    struct Call: Equatable {
        var name: String
        var input: String
        var kind: String?
    }

    private let lock = NSLock()
    private var text = ""
    private var thought = ""
    private var calls: [String: Call] = [:]
    private var finishedCalls: Set<String> = []

    func events(_ update: [String: Any]) -> [StreamEvent] {
        lock.withLock {
            let meta = (update["_meta"] as? [String: Any])?["kiro"] as? [String: Any]
            if meta?["replay"] as? Bool == true { return [] }
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                let events = flushThought()
                text += Self.chunkText(update)
                return events
            case "agent_thought_chunk":
                let events = flushText()
                thought += Self.chunkText(update)
                return events
            case "tool_call":
                return flush() + toolCall(update)
            case "tool_call_update":
                return flush() + toolCallUpdate(update)
            case "session_info_update":
                switch meta?["kind"] as? String {
                case "turn_start": return flush() + [.turnStarted]
                case "turn_end": return flush()
                default: return []
                }
            default:
                return []
            }
        }
    }

    // Whatever text or thinking is still held, for the moment the turn ends.
    func finish() -> [StreamEvent] { lock.withLock { flush() } }

    // The call a permission request is about, as the stream described it.
    func call(_ id: String) -> Call? { lock.withLock { calls[id] } }

    // MARK: - Private

    private func flush() -> [StreamEvent] { flushThought() + flushText() }

    private func flushText() -> [StreamEvent] {
        defer { text = "" }
        return text.isBlank ? [] : [.text(text)]
    }

    private func flushThought() -> [StreamEvent] {
        defer { thought = "" }
        return thought.isBlank ? [] : [.thinking(thought)]
    }

    private func toolCall(_ update: [String: Any]) -> [StreamEvent] {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return [] }
        var events: [StreamEvent] = []
        if calls[id] == nil {
            let call = Self.call(kind: update["kind"] as? String,
                                 title: update["title"] as? String,
                                 input: update["rawInput"] as? [String: Any] ?? [:])
            calls[id] = call
            events.append(.toolUse(ToolUse(id: id, name: call.name, input: call.input)))
        }
        return events + result(of: id, update)
    }

    private func toolCallUpdate(_ update: [String: Any]) -> [StreamEvent] {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return [] }
        // An update for a call the stream never announced still has to show up, or its
        // result would have nowhere to land.
        if calls[id] == nil { return toolCall(update) }
        return result(of: id, update)
    }

    private func result(of id: String, _ update: [String: Any]) -> [StreamEvent] {
        let status = update["status"] as? String
        guard status == "completed" || status == "failed",
              finishedCalls.insert(id).inserted else { return [] }
        let raw = update["rawOutput"]
        let fields = raw as? [String: Any]
        let output = (fields?["output"] as? String)
            ?? (fields?["message"] as? String)
            ?? (raw as? String)
            ?? Self.contentText(update["content"])
        let exitCode = (fields?["exitCode"] as? NSNumber)?.intValue
        return [.toolResult(id: id, output: StreamEvent.truncated(output),
                            isError: status == "failed", exitCode: exitCode)]
    }

    private static func chunkText(_ update: [String: Any]) -> String {
        (update["content"] as? [String: Any])?["text"] as? String ?? ""
    }

    // ACP's own way of carrying a result: a list of content blocks.
    private static func contentText(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { block in
            ((block["content"] as? [String: Any])?["text"] as? String) ?? block["text"] as? String
        }.joined(separator: "\n")
    }

    // What Kiro did, said in the words the rest of the app already uses for it. ACP names
    // a call's kind and Kiro's tools take arguments under names of their own, so the ones
    // the app reads are renamed onto the names Claude Code sends. Anything else keeps
    // Kiro's own title and shows its arguments as they came.
    static func call(kind: String?, title: String?, input: [String: Any]) -> Call {
        let path = input["path"] ?? input["file_path"]
        if let command = input["command"] as? String, kind == "execute" || kind == nil {
            return Call(name: "Bash", input: json(["command": command]), kind: kind)
        }
        switch kind {
        case "edit":
            if let old = input["oldStr"] ?? input["old_str"] ?? input["old_string"] {
                return Call(name: "Edit", input: json([
                    "file_path": path, "old_string": old,
                    "new_string": input["newStr"] ?? input["new_str"] ?? input["new_string"],
                ]), kind: kind)
            }
            return Call(name: "Write", input: json([
                "file_path": path,
                "content": input["text"] ?? input["content"] ?? input["file_text"],
            ]), kind: kind)
        case "read" where path != nil:
            return Call(name: "Read", input: json(["file_path": path]), kind: kind)
        case "search":
            return Call(name: "Grep", input: json([
                "pattern": input["pattern"] ?? input["query"], "path": path,
            ]), kind: kind)
        case "fetch":
            if let url = input["url"] {
                return Call(name: "WebFetch", input: json(["url": url]), kind: kind)
            }
            return Call(name: "WebSearch", input: json(["query": input["query"]]), kind: kind)
        default:
            let name = title.flatMap { $0.isBlank ? nil : $0 } ?? kind ?? "Tool"
            return Call(name: name, input: json(input), kind: kind)
        }
    }

    // The call's input as the JSON object the app reads every call's input as. Fields
    // without a value are left out rather than sent as null.
    private static func json(_ fields: [String: Any?]) -> String {
        let present = fields.compactMapValues { $0 }.filter { !($0.value is NSNull) }
        guard JSONSerialization.isValidJSONObject(present),
              let data = try? JSONSerialization.data(
                withJSONObject: present,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
