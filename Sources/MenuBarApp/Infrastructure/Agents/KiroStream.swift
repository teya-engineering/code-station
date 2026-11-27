import Foundation

// What Kiro said on its ACP stream, folded onto the events the rest of the app already
// reads. Kiro speaks the Agent Client Protocol: every change to the session arrives as a
// `session/update` notification, the text in small chunks, and every tool as a call
// followed by updates that carry its result. Each chunk is handed on as it arrives, so
// the reply is written out as Kiro writes it. A chunk says whether it carries on the
// block before it; a tool call or a turn boundary ends the block.
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
    // Importing a past session reads its replay on purpose; a live session drops it.
    private let acceptsReplay: Bool

    init(acceptsReplay: Bool = false) {
        self.acceptsReplay = acceptsReplay
    }
    // Whether the last piece said was text or thinking, so the next piece of the same
    // kind carries on that block rather than opening a new one.
    private var textOpen = false
    private var thoughtOpen = false
    private var calls: [String: Call] = [:]
    private var finishedCalls: Set<String> = []
    // Kiro's own bookkeeping, such as loading an MCP tool before using it. Not work worth
    // a row, so its result is not worth one either.
    private var ignoredCalls: Set<String> = []
    // Credits this process has spent, reported as a running total the way the runner
    // reads every usage report: it records what has grown since the one before.
    private var credits: Double = 0

    func events(_ update: [String: Any]) -> [StreamEvent] {
        lock.withLock {
            let meta = (update["_meta"] as? [String: Any])?["kiro"] as? [String: Any]
            if meta?["replay"] as? Bool == true, !acceptsReplay { return [] }
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                let text = Self.chunkText(update)
                guard !text.isEmpty else { return [] }
                thoughtOpen = false
                defer { textOpen = true }
                return [.textChunk(text, continuing: textOpen)]
            case "agent_thought_chunk":
                let text = Self.chunkText(update)
                guard !text.isEmpty else { return [] }
                textOpen = false
                defer { thoughtOpen = true }
                return [.thinkingChunk(text, continuing: thoughtOpen)]
            case "tool_call":
                closeBlocks()
                return toolCall(update)
            case "tool_call_update":
                closeBlocks()
                return toolCallUpdate(update)
            case "session_info_update":
                switch meta?["kind"] as? String {
                case "turn_start":
                    closeBlocks()
                    return [.turnStarted]
                case "turn_end":
                    closeBlocks()
                    return []
                case "turn_completion":
                    // What the turn cost, one summary per model request it made.
                    let spent = (meta?["promptTurnSummaries"] as? [[String: Any]] ?? [])
                        .filter { ($0["unit"] as? String ?? "credit") == "credit" }
                        .compactMap { ($0["usage"] as? NSNumber)?.doubleValue }
                        .reduce(0, +)
                    guard spent > 0 else { return [] }
                    credits += spent
                    return [.usage(TurnUsage(credits: credits))]
                default: return []
                }
            default:
                return []
            }
        }
    }

    // The turn is over: whatever comes next starts a block of its own. Nothing is held
    // back, so there is nothing left to hand on.
    func finish() -> [StreamEvent] {
        lock.withLock { closeBlocks() }
        return []
    }

    // The call a permission request is about, as the stream described it.
    func call(_ id: String) -> Call? { lock.withLock { calls[id] } }

    // MARK: - Private

    private func closeBlocks() {
        textOpen = false
        thoughtOpen = false
    }

    private func toolCall(_ update: [String: Any]) -> [StreamEvent] {
        guard let id = update["toolCallId"] as? String, !id.isEmpty,
              !ignoredCalls.contains(id) else { return [] }
        if calls[id] == nil, Self.isBookkeeping(title: update["title"] as? String,
                                                input: update["rawInput"] as? [String: Any] ?? [:]) {
            ignoredCalls.insert(id)
            return []
        }
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
        guard let id = update["toolCallId"] as? String, !id.isEmpty,
              !ignoredCalls.contains(id) else { return [] }
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
        // An MCP tool is titled "@server/tool"; it reads the way other agents' MCP calls do.
        if let title, title.hasPrefix("@"), let slash = title.firstIndex(of: "/") {
            let server = title[title.index(after: title.startIndex)..<slash]
            return mcpCall(server: String(server), tool: String(title[title.index(after: slash)...]))
        }
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

    static func mcpCall(server: String, tool: String) -> Call {
        Call(name: "MCP", input: "\(server).\(tool)", kind: "mcp")
    }

    // A permission request for an MCP tool can arrive before its call does; the request
    // names it as "server/tool".
    static func mcpCall(resource: String) -> Call? {
        guard let slash = resource.firstIndex(of: "/") else { return nil }
        return mcpCall(server: String(resource[..<slash]),
                       tool: String(resource[resource.index(after: slash)...]))
    }

    // Kiro loads an MCP tool with a call of its own before using it.
    static func isBookkeeping(title: String?, input: [String: Any]) -> Bool {
        title == "Tool Load" || (input["id"] as? String)?.hasPrefix("tool::") == true
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
