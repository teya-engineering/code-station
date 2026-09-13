import Foundation

// One meaningful thing the Copilot CLI said on its stdout stream, folded onto the same
// events Claude Code produces so nothing past the runner cares which agent ran. Copilot
// prints its own session log in `copilot -p --output-format json`: a message or a tool
// call per line, a usage report after every model call, and one last line carrying the
// exit code. Usage arrives per call rather than per turn and the last line names no
// error, so this keeps a little state for the turn where the other parsers keep none.
// As with them, anything unrecognised is dropped instead of failing the turn.
final class CopilotStream: @unchecked Sendable {
    private let lock = NSLock()
    // Running totals for the turn: the runner records every report as what has grown
    // since the one before it.
    private var usage = TurnUsage()
    private var lastError: String?
    private var sawReasoning = false
    // Tool calls that were not worth a row, so their results are not worth one either.
    private var ignoredCalls: Set<String> = []

    func parse(_ line: String) -> [StreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let payload = object["data"] as? [String: Any] ?? [:]

        lock.lock()
        defer { lock.unlock() }

        switch object["type"] as? String {
        case "session.start":
            guard let id = payload["sessionId"] as? String, !id.isEmpty else { return [] }
            return [.initialized(claudeSessionID: id)]

        case "assistant.message":
            // The message carries the whole text; the deltas before it are ignored the
            // way Codex's started items are. Its tool requests arrive again as calls.
            var events: [StreamEvent] = []
            let parent = Self.parentCall(of: payload)
            if let text = payload["content"] as? String, !text.isEmpty {
                events.append(parent.map { .agentText(parentID: $0, text: text) } ?? .text(text))
            }
            // Some models report their reasoning only on the message. When reasoning
            // events are on the stream they are the same words, so only one speaks.
            if parent == nil, !sawReasoning,
               let reasoning = payload["reasoningText"] as? String, !reasoning.isEmpty {
                events.insert(.thinking(reasoning), at: 0)
            }
            return events

        case "assistant.reasoning":
            guard Self.parentCall(of: payload) == nil,
                  let text = payload["content"] as? String, !text.isEmpty else { return [] }
            sawReasoning = true
            return [.thinking(text)]

        case "tool.execution_start":
            guard let id = payload["toolCallId"] as? String, !id.isEmpty,
                  let name = payload["toolName"] as? String else { return [] }
            guard let call = Self.call(named: name,
                                       arguments: payload["arguments"] as? [String: Any] ?? [:],
                                       server: payload["mcpServerName"] as? String,
                                       serverTool: payload["mcpToolName"] as? String) else {
                ignoredCalls.insert(id)
                return []
            }
            return [.toolUse(ToolUse(id: id, name: call.name, input: call.input,
                                     parentID: Self.parentCall(of: payload)))]

        case "tool.execution_complete":
            guard let id = payload["toolCallId"] as? String, !id.isEmpty else { return [] }
            guard !ignoredCalls.contains(id) else {
                ignoredCalls.remove(id)
                return []
            }
            let succeeded = payload["success"] as? Bool ?? true
            let result = payload["result"] as? [String: Any]
            var output = result?["content"] as? String ?? ""
            if output.isEmpty, !succeeded,
               let message = (payload["error"] as? [String: Any])?["message"] as? String {
                output = message
            }
            return [.toolResult(id: id, output: StreamEvent.truncated(output),
                                isError: !succeeded, exitCode: nil)]

        case "assistant.usage":
            let input = payload["inputTokens"] as? Int ?? 0
            let cacheRead = payload["cacheReadTokens"] as? Int ?? 0
            let cacheWrite = payload["cacheWriteTokens"] as? Int ?? 0
            usage.inputTokens += input
            usage.outputTokens += payload["outputTokens"] as? Int ?? 0
            usage.cacheReadTokens += cacheRead
            usage.cacheWriteTokens += cacheWrite
            // A subagent's calls count towards what the turn spent but have a window of
            // their own; only the main loop says how full the conversation's window is.
            let mainLoop = Self.parentCall(of: payload) == nil
                && (payload["initiator"] as? String).map { $0.isEmpty || $0 == "user" } ?? true
            guard mainLoop else { return [.usage(usage)] }
            if let model = payload["model"] as? String, !model.isEmpty { usage.model = model }
            if let window = payload["maxPromptTokens"] as? Int, window > 0 {
                usage.contextWindow = window
            }
            var events: [StreamEvent] = [.usage(usage)]
            let prompt = input + cacheRead + cacheWrite
            if prompt > 0 { events.append(.context(tokens: prompt)) }
            return events

        case "session.compaction_complete":
            guard payload["success"] as? Bool ?? true else { return [] }
            return [.compacted(preTokens: payload["preCompactionTokens"] as? Int,
                               postTokens: payload["postCompactionTokens"] as? Int)]

        case "session.error":
            // Whether the error ended the turn is only known from the last line's exit
            // code, so the words are kept for it rather than acted on here.
            if let message = payload["message"] as? String, !message.isEmpty {
                lastError = message
            }
            return []

        case "result":
            // The end of the run rather than of the session, and the only line that
            // carries the session id in prompt mode.
            var events: [StreamEvent] = []
            if let id = object["sessionId"] as? String, !id.isEmpty {
                events.append(.initialized(claudeSessionID: id))
            }
            let status = object["exitCode"] as? Int ?? 0
            let failed = status != 0
            events.append(.finished(isError: failed,
                                    message: failed ? lastError ?? "Copilot exited with status \(status)."
                                                    : nil))
            return events

        default:
            return []
        }
    }

    // MARK: - Private

    private static func parentCall(of payload: [String: Any]) -> String? {
        guard let id = payload["parentToolCallId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    // What Copilot did, said in the words the rest of the app already uses for it. Its
    // built-in tools take arguments under names of their own, so the ones the app reads
    // are renamed onto the names Claude Code sends. A tool with no name here keeps its
    // own and shows its arguments as they came.
    private static func call(named name: String, arguments: [String: Any],
                             server: String?, serverTool: String?) -> (name: String, input: String)? {
        if let server, !server.isEmpty {
            return ("MCP", [server, serverTool ?? name].joined(separator: "."))
        }
        switch name {
        case "view":
            return ("Read", json(["file_path": arguments["path"]]))
        case "edit", "str_replace_editor":
            return ("Edit", json(["file_path": arguments["path"],
                                  "old_string": arguments["old_str"],
                                  "new_string": arguments["new_str"]]))
        case "create":
            return ("Write", json(["file_path": arguments["path"],
                                   "content": arguments["file_text"]]))
        case "bash", "powershell":
            return ("Bash", json(["command": arguments["command"],
                                  "description": arguments["description"]]))
        case "grep":
            return ("Grep", json(["pattern": arguments["pattern"], "path": arguments["path"]]))
        case "glob":
            return ("Glob", json(["pattern": arguments["pattern"], "path": arguments["path"]]))
        case "web_fetch":
            return ("WebFetch", json(["url": arguments["url"]]))
        case "task":
            return ("Agent", json(["name": arguments["agent_type"],
                                   "description": arguments["description"],
                                   "prompt": arguments["prompt"]]))
        case "report_intent", "update_todo", "todo", "store_memory":
            // Progress notes and bookkeeping, not work worth a row.
            return nil
        default:
            return (name, json(arguments))
        }
    }

    // The call's input as the JSON object the app reads every call's input as. Fields
    // without a value are left out rather than sent as null.
    private static func json(_ fields: [String: Any?]) -> String {
        let present = fields.compactMapValues { $0 }
        guard JSONSerialization.isValidJSONObject(present),
              let data = try? JSONSerialization.data(
                withJSONObject: present,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
