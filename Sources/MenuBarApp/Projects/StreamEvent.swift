import Foundation

// One meaningful thing the Claude Code CLI said on its stdout stream. The CLI emits far
// more than this (rate limits, token counters, session state) and adds new kinds over
// time, so anything unrecognised is dropped instead of failing the turn.
enum StreamEvent: Sendable {
    case initialized(claudeSessionID: String)
    case text(String)
    // What the model worked out to itself before answering. It is part of the turn but
    // not of the answer, so it is kept apart from the text.
    case thinking(String)
    // Something an agent said while working, named by the call that started it. It is
    // not part of the conversation - the agent reports back through its result - so it
    // is only worth the one line that says the agent is still going.
    case agentText(parentID: String, text: String)
    case toolUse(ToolUse)
    case toolResult(id: String, output: String, isError: Bool)
    // The agent asking something back. The turn is parked until it is answered.
    case permissionRequest(PermissionRequest)
    case permissionWithdrawn(id: String)
    // Something the CLI asked for that this app cannot do. It still has to be answered:
    // the turn does not move again until every request it is waiting on has a reply.
    case unanswerable(requestID: String, subtype: String)
    // Where the account's usage windows stand, sent whenever they move.
    case rateLimit(RateLimit)
    // What the finished turn cost, reported alongside its result.
    case usage(TurnUsage)
    // How big the prompt was on the last request the main loop made, which is how much of
    // the window is in use right now.
    case context(tokens: Int)
    // The conversation behind this point has been replaced by a summary, with the size of
    // it before and after. The sizes are what makes a compaction worth reporting: they are
    // the difference it made, and the one after is how full the window is now.
    case compacted(preTokens: Int?, postTokens: Int?)
    // Which background tasks the CLI still has running, sent whole whenever the set
    // changes. A turn that ends while this is not empty is not really over: the CLI runs
    // a follow-up turn when a task finishes, but only if its process is still alive.
    case backgroundTasks([BackgroundTask])
    // What kind of agent is running behind a background task. Only the event that starts
    // a task says it, while the list of live tasks that follows names them by their work
    // alone, so it arrives on its own and is merged back onto the list.
    case taskAgent(id: String, name: String)
    // The transport dropped but the CLI is still running and may reconnect on its own.
    // This is status, not the result of the turn.
    case streamError(String)
    case finished(isError: Bool, message: String?)
}

// A command or agent the CLI started and left running behind the turn. The description is
// the CLI's own words for it, and it is the only thing that tells a build that will end
// apart from a server that never will, so it is carried rather than counted.
struct BackgroundTask: Identifiable, Equatable, Sendable {
    let id: String
    // What the CLI calls the kind of task: "local_bash" for a shell command, "local_agent"
    // for an agent it spawned. New kinds appear over time, so it is kept as it arrived.
    let kind: String?
    let description: String?
    // Which agent is doing the work: a subagent type, a named agent, a workflow. Two
    // agents sent after the same thing read the same without it, and it is the name the
    // CLIs use for a running agent themselves.
    var agentName: String?

    var label: String {
        let named = [agentName, description].compactMap { $0 }.filter { !$0.isEmpty }
        if !named.isEmpty { return named.joined(separator: " · ") }
        return switch kind {
        case "local_bash": "a command"
        case "local_agent": "an agent"
        default: "a background task"
        }
    }
}

extension StreamEvent {
    // A tool can return a whole file, and every result is persisted with the session, so
    // very long output is cut down before it reaches the store.
    static let maxToolOutput = 20_000

    // Whether this is the turn answering rather than the CLI reporting on itself. A
    // result that arrives before any of these has answered nothing, which is what tells
    // a turn the app did not ask for apart from the one it is reading.
    var isAnswering: Bool {
        switch self {
        case .text, .thinking, .agentText, .toolUse, .toolResult, .permissionRequest,
             .compacted:
            true
        default:
            false
        }
    }

    // Logs describe the protocol without copying prompts, source code, tool input, or
    // command output into a second long-lived file.
    var logSummary: String {
        switch self {
        case .initialized:
            "initialized"
        case .text(let text):
            "text bytes=\(text.utf8.count)"
        case .thinking(let text):
            "thinking bytes=\(text.utf8.count)"
        case .agentText(let parentID, let text):
            "agent text parent=\(parentID) bytes=\(text.utf8.count)"
        case .toolUse(let tool):
            "tool use name=\(tool.name) id=\(tool.id)"
        case .toolResult(let id, let output, let isError):
            "tool result id=\(id) bytes=\(output.utf8.count) error=\(isError)"
        case .permissionRequest(let request):
            "permission request tool=\(request.toolName) id=\(request.id)"
        case .permissionWithdrawn(let id):
            "permission withdrawn id=\(id)"
        case .unanswerable(let requestID, let subtype):
            "unsupported request subtype=\(subtype) id=\(requestID)"
        case .rateLimit:
            "rate limit updated"
        case .usage:
            "usage updated"
        case .context(let tokens):
            "context tokens=\(tokens)"
        case .compacted(let preTokens, let postTokens):
            "compacted pre=\(preTokens.map(String.init) ?? "unknown") post=\(postTokens.map(String.init) ?? "unknown")"
        case .backgroundTasks(let tasks):
            // The descriptions are the CLI's own words about what it is running and can
            // name files or commands, so only how many there are goes in the log.
            "background tasks count=\(tasks.count)"
        case .taskAgent(let id, let name):
            "task agent id=\(id) name=\(name)"
        case .streamError(let message):
            "stream error category=\(Self.streamErrorCategory(message)) "
                + "messageBytes=\(message.utf8.count)"
        case .finished(let isError, let message):
            "finished error=\(isError) messageBytes=\(message?.utf8.count ?? 0)"
        }
    }

    // Error text can include endpoint details or account data. A small category gives
    // diagnostics enough shape without copying the payload into the app log.
    static func streamErrorCategory(_ message: String) -> String {
        let message = message.lowercased()
        if message.contains("rate limit") || message.contains("too many requests")
            || message.contains("429") {
            return "rate-limit"
        }
        if message.contains("timed out") || message.contains("timeout") {
            return "timeout"
        }
        if message.contains("reconnect") {
            return "reconnecting"
        }
        if message.contains("connection") || message.contains("disconnect")
            || message.contains("socket") || message.contains("closed")
            || message.contains("eof") {
            return "connection"
        }
        if message.contains("unauthorized") || message.contains("authentication")
            || message.contains("sign in") || message.contains("401") {
            return "authentication"
        }
        return "other"
    }

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
            // Permission is the only one of these the app knows how to answer. The rest -
            // a dialog, a hook callback, an MCP relay - belong to a host this app is not
            // pretending to be, but every one of them still gets a reply: the CLI blocks
            // on the request id until something comes back, so dropping one is what leaves
            // a turn thinking forever with nothing on screen to say why.
            guard let id = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any] else { return [] }
            let subtype = request["subtype"] as? String ?? "unknown"
            guard subtype == "can_use_tool",
                  let parsed = PermissionRequest.parse(id: id, request: request,
                                                       projectPath: projectPath)
            else { return [.unanswerable(requestID: id, subtype: subtype)] }
            return [.permissionRequest(parsed)]

        // The agent gave up on a question of its own accord, usually because the turn was
        // interrupted. The card has to go, or it would answer a request nobody is holding.
        case "control_cancel_request":
            guard let id = object["request_id"] as? String else { return [] }
            return [.permissionWithdrawn(id: id)]

        case "system":
            switch object["subtype"] as? String {
            case "init":
                guard let id = object["session_id"] as? String, !id.isEmpty else { return [] }
                return [.initialized(claudeSessionID: id)]
            case "background_tasks_changed":
                let tasks = (object["tasks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
                return [.backgroundTasks(tasks.compactMap { task in
                    (task["task_id"] as? String).map {
                        BackgroundTask(id: $0,
                                       kind: task["task_type"] as? String,
                                       description: task["description"] as? String)
                    }
                })]
            case "task_started":
                guard let id = object["task_id"] as? String, !id.isEmpty,
                      let name = (object["subagent_type"] as? String
                                  ?? object["workflow_name"] as? String),
                      !name.isEmpty
                else { return [] }
                return [.taskAgent(id: id, name: name)]
            case "compact_boundary":
                // The stream spells these with underscores and the CLI's own history file
                // spells the same fields in camel case, so both are accepted rather than
                // betting the reading on which one arrives.
                let metadata = object["compact_metadata"] as? [String: Any]
                    ?? object["compactMetadata"] as? [String: Any] ?? [:]
                return [.compacted(preTokens: count(metadata, "pre_tokens", "preTokens"),
                                   postTokens: count(metadata, "post_tokens", "postTokens"))]
            default:
                return []
            }

        case "assistant":
            let parent = parentToolUseID(of: object)
            var events = contentBlocks(of: object).compactMap { assistantEvent($0, parentID: parent) }
            if let tokens = promptSize(of: object) { events.append(.context(tokens: tokens)) }
            return events

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

    // The first of these names the payload actually uses, for fields the CLI spells one
    // way on the stream and another in the history file.
    private static func count(_ container: [String: Any], _ names: String...) -> Int? {
        names.lazy.compactMap { container[$0] as? Int }.first
    }

    // How many tokens the model was sent on this request: everything it read, cached or
    // not. A turn makes one request per round of tool calls and each one re-reads the
    // whole conversation, so only the newest of these says how full the window is - the
    // totals on the result event add them all up and run far past the window.
    //
    // A subagent has a window of its own, and its messages are tagged with the tool call
    // that started it. Those are left out: the meter is about the main conversation.
    private static func promptSize(of object: [String: Any]) -> Int? {
        guard parentToolUseID(of: object) == nil,
              let message = object["message"] as? [String: Any],
              let counts = message["usage"] as? [String: Any] else { return nil }
        let tokens = (counts["input_tokens"] as? Int ?? 0)
            + (counts["cache_read_input_tokens"] as? Int ?? 0)
            + (counts["cache_creation_input_tokens"] as? Int ?? 0)
        return tokens > 0 ? tokens : nil
    }

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

    // Which agent a stream message came from, named by the call that started it. Absent
    // on everything the main loop itself said.
    private static func parentToolUseID(of object: [String: Any]) -> String? {
        guard let id = object["parent_tool_use_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return (message["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func assistantEvent(_ block: [String: Any], parentID: String?) -> StreamEvent? {
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            guard let parentID else { return .text(text) }
            return .agentText(parentID: parentID, text: text)
        case "thinking":
            // An agent's thinking stays with the agent: only its report comes back to
            // the conversation. Redacted thinking arrives encrypted and is not shown.
            guard parentID == nil, let text = block["thinking"] as? String,
                  !text.isEmpty else { return nil }
            return .thinking(text)
        case "tool_use":
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return .toolUse(ToolUse(id: id, name: name, input: pretty(block["input"]),
                                    parentID: parentID))
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

    // Shared with the Codex parser, which cuts its command output the same way.
    static func truncated(_ text: String) -> String {
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
