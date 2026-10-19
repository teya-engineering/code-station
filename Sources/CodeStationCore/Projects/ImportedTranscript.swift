import Foundation

public struct ImportedTranscript {
    private var messages: [ChatMessage] = []
    private var reply: ChatMessage?

    public mutating func prompt(_ text: String, at date: Date?) {
        close()
        messages.append(ChatMessage(role: .user, text: text, date: date ?? .distantPast))
    }

    public mutating func note(_ text: String, at date: Date?) {
        close()
        messages.append(ChatMessage(role: .system, text: text, date: date ?? .distantPast))
    }

    public mutating func apply(_ event: StreamEvent, at date: Date?) {
        var message = reply ?? ChatMessage(role: .assistant, date: date ?? .distantPast)
        switch event {
        case .text(let text):
            if !message.text.isEmpty { message.text += "\n\n" }
            message.text += text
        case .thinking(let text):
            var thought = ThinkingSegment(text: text)
            thought.textOffset = message.text.count
            thought.toolOffset = message.tools.count
            message.thinking = (message.thinking ?? []) + [thought]
        case .toolUse(var tool):
            guard tool.parentID == nil else { return }
            tool.textOffset = message.text.count
            tool.startedAt = date
            message.tools.append(tool)
        case .toolResult(let id, let output, let isError, let exitCode):
            guard let i = message.tools.firstIndex(where: { $0.id == id }) else { return }
            message.tools[i].result = output
            message.tools[i].isError = isError
            message.tools[i].exitCode = exitCode
            message.tools[i].finishedAt = date
        default: return
        }
        reply = message
    }

    public mutating func close() {
        guard var message = reply else { return }
        reply = nil
        for i in message.tools.indices where message.tools[i].result == nil {
            message.tools[i].result = ""
        }
        if !message.isEmpty { messages.append(message) }
    }

    public mutating func finish() -> [ChatMessage] {
        close()
        return messages
    }
}

public enum CodexTranscriptImport {
    public static func append(_ turn: [String: Any], to transcript: inout ImportedTranscript, fallbackDate: Date?) {
        let start = (turn["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? fallbackDate
        let end = (turn["completedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? start
        for var item in turn["items"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "userMessage":
                let blocks = item["content"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { block -> String? in
                    switch block["type"] as? String {
                    case "text": block["text"] as? String
                    case "image", "localImage": "[image]"
                    default: nil
                    }
                }.joined(separator: "\n\n")
                if !text.isEmpty { transcript.prompt(text, at: start) }
                continue
            case "agentMessage": item["type"] = "agent_message"
            case "reasoning": item["text"] = (item["summary"] as? [String] ?? []).joined(separator: "\n\n")
            case "commandExecution":
                item["type"] = "command_execution"
                item["aggregated_output"] = item["aggregatedOutput"]
                item["exit_code"] = item["exitCode"]
            case "fileChange":
                item["type"] = "file_change"
                item["changes"] = (item["changes"] as? [[String: Any]] ?? []).map { raw in
                    var change = raw
                    if let kind = raw["kind"] as? [String: Any] { change["kind"] = kind["type"] }
                    return change
                }
            case "mcpToolCall": item["type"] = "mcp_tool_call"
            case "webSearch": item["type"] = "web_search"
            case "contextCompaction":
                transcript.note("Codex compacted the conversation here.", at: end)
                continue
            default: break
            }
            for event in StreamEvent.codexEvents(["type": "item.started", "item": item]) {
                transcript.apply(event, at: start)
            }
            for event in StreamEvent.codexEvents(["type": "item.completed", "item": item]) {
                transcript.apply(event, at: end)
            }
        }
        transcript.close()
    }
}

public enum CopilotTranscriptImport {
    public static func messages(from file: URL) throws -> [ChatMessage] {
        var transcript = ImportedTranscript()
        var stream = CopilotStream()
        try SessionHistoryLines.read(file) { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ephemeral"] as? Bool != true, object["agentId"] as? String == nil else { return }
            let payload = object["data"] as? [String: Any] ?? [:]
            guard payload["parentToolCallId"] as? String == nil else { return }
            let date = ClaudeTranscriptImport.date(object["timestamp"])
            switch object["type"] as? String {
            case "user.message":
                guard let text = payload["content"] as? String, !text.isEmpty else { return }
                transcript.prompt(text, at: date)
                stream = CopilotStream()
            case "session.compaction_complete":
                if payload["success"] as? Bool != false {
                    transcript.note("Copilot compacted the conversation here.", at: date)
                }
            case "abort": transcript.note("Interrupted.", at: date)
            default:
                for event in stream.events(object) { transcript.apply(event, at: date) }
            }
        }
        return transcript.finish()
    }
}

public enum SessionHistoryLines {
    public static func read(_ file: URL, take: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let buffer = LineBuffer()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            for line in buffer.lines(from: chunk) { try take(line) }
        }
        for line in buffer.flush() { try take(line) }
    }
}
