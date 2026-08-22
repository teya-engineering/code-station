import Foundation

// One meaningful thing the Codex CLI said on its stdout stream, folded onto the same
// events Claude Code produces so nothing past the runner cares which agent ran. Codex
// speaks its own JSONL dialect in `codex exec --json`: a thread starts, items begin and
// complete, and the turn ends with usage or a failure. As with Claude Code, anything
// unrecognised is dropped instead of failing the turn.
extension StreamEvent {
    static func parseCodex(_ line: String) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        switch object["type"] as? String {
        case "thread.started":
            // The thread id is what `codex exec resume` needs, the way Claude Code's
            // session id feeds --resume.
            guard let id = object["thread_id"] as? String, !id.isEmpty else { return [] }
            return [.initialized(claudeSessionID: id)]

        case "item.started":
            return itemEvents(object, completed: false)

        case "item.completed":
            return itemEvents(object, completed: true)

        case "turn.completed":
            var events: [StreamEvent] = []
            if let counts = object["usage"] as? [String: Any] {
                var usage = TurnUsage()
                let input = counts["input_tokens"] as? Int ?? 0
                let cached = counts["cached_input_tokens"] as? Int ?? 0
                // Codex counts cached tokens inside input_tokens; the app's totals keep
                // them apart, the way Claude Code reports them.
                usage.inputTokens = max(0, input - cached)
                usage.cacheReadTokens = cached
                usage.outputTokens = counts["output_tokens"] as? Int ?? 0
                events.append(.usage(usage))
            }
            events.append(.finished(isError: false, message: nil))
            return events

        case "turn.failed":
            let error = object["error"] as? [String: Any]
            return [.finished(isError: true, message: error?["message"] as? String)]

        case "error":
            return [.streamError(object["message"] as? String
                ?? "Codex lost its connection and is trying to recover.")]

        default:
            return []
        }
    }

    // MARK: - Private

    // What Codex did to the file, said in the words the rest of the app already uses for
    // it. Its own kinds are add, delete and update.
    private static func editVerb(_ kind: String?) -> String {
        switch kind {
        case "add": "Write"
        case "delete": "Delete"
        default: "Edit"
        }
    }

    // Codex sends an edit as fields rather than as JSON, while the app reads every call's
    // input as the JSON object Claude Code sends. Encoding it here is what lets one
    // presentation cover both agents.
    private static func json(_ fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let text = String(data: data, encoding: .utf8)
        else { return fields["file_path"] ?? "" }
        return text
    }

    // Items are Codex's tool calls and messages. A command starts and later completes,
    // so it maps onto a tool call and its result. A message only matters once it is
    // complete: the completed item carries the whole text again, so acting on the
    // started one would say everything twice.
    private static func itemEvents(_ object: [String: Any], completed: Bool) -> [StreamEvent] {
        guard let item = object["item"] as? [String: Any],
              let id = item["id"] as? String else { return [] }
        let failed = item["status"] as? String == "failed"

        switch (item["item_type"] ?? item["type"]) as? String {
        case "agent_message", "assistant_message":
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]

        case "reasoning":
            // Codex reports a summary of its reasoning between steps. Like a message,
            // only the completed item carries the whole text.
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.thinking(text)]

        case "command_execution":
            guard completed else {
                return [.toolUse(ToolUse(id: id, name: "Bash",
                                         input: item["command"] as? String ?? ""))]
            }
            let isError = (item["exit_code"] as? Int).map { $0 != 0 } ?? failed
            return [.toolResult(id: id,
                                output: truncated(item["aggregated_output"] as? String ?? ""),
                                isError: isError)]

        case "file_change":
            // Codex reports every file it touched in one item, so the item becomes one
            // finished call per file - the shape Claude Code's edits already arrive in,
            // and the only shape that gives each file a diff of its own. Codex works out
            // that diff itself and sends it along, so nothing here has to.
            guard completed else { return [] }
            let changes = (item["changes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            return changes.enumerated().flatMap { index, change -> [StreamEvent] in
                guard let path = change["path"] as? String else { return [] }
                var fields: [String: String] = ["file_path": path]
                if let diff = change["diff"] as? String, !diff.isEmpty { fields["diff"] = diff }
                // One item, several calls: the item's own id belongs to the first of them
                // and the rest are numbered off it, so every call still has an id of its
                // own for its result to land on.
                let callID = index == 0 ? id : "\(id)#\(index)"
                let tool = ToolUse(id: callID, name: editVerb(change["kind"] as? String),
                                   input: json(fields))
                return [.toolUse(tool), .toolResult(id: callID, output: "", isError: failed)]
            }

        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String]
                .compactMap { $0 }.joined(separator: ".")
            guard completed else {
                return [.toolUse(ToolUse(id: id, name: "MCP", input: name))]
            }
            return [.toolResult(id: id, output: "", isError: failed)]

        case "web_search":
            guard completed else { return [] }
            return [.toolUse(ToolUse(id: id, name: "WebSearch",
                                     input: item["query"] as? String ?? "")),
                    .toolResult(id: id, output: "", isError: false)]

        default:
            // Todo lists and whatever Codex adds next are not worth a row.
            return []
        }
    }
}
