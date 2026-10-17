import Foundation

// Turns a conversation Claude Code wrote to its own history file into the messages the
// app keeps, so a session started in the terminal reads the same as one started here.
//
// The file is a list of records, and the ones that matter have the same shape as the
// CLI's stream output, so their content goes through `StreamEvent.parse`. What the stream
// never carries is handled here: the prompts themselves (the app writes those on its own
// when it runs a turn), the records Claude Code keeps for its own bookkeeping, and the
// turns of subagents, which belong in their call rather than in the conversation.
enum ClaudeTranscriptImport {
    static func messages(from file: URL, projectPath: String) throws -> [ChatMessage] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let buffer = LineBuffer()
        var fold = Fold(projectPath: projectPath)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for line in buffer.lines(from: chunk) { fold.take(line) }
        }
        for line in buffer.flush() { fold.take(line) }
        return fold.finish()
    }

    static func messages(fromLines lines: [String], projectPath: String = "") -> [ChatMessage] {
        var fold = Fold(projectPath: projectPath)
        for line in lines { fold.take(line) }
        return fold.finish()
    }

    // What the person typed in a user record, or nil when the record is not a prompt:
    // a tool result, a note Claude Code added for the model, or a command's output.
    static func prompt(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "user", !isBookkeeping(object),
              let message = object["message"] as? [String: Any] else { return nil }

        var text = ""
        var images = 0
        switch message["content"] {
        case let string as String:
            text = string
        case let blocks as [Any]:
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text":
                    if let part = block["text"] as? String {
                        text += text.isEmpty ? part : "\n\n" + part
                    }
                case "image":
                    images += 1
                default:
                    break
                }
            }
        default:
            return nil
        }

        let trimmed = text.trimmed
        if trimmed.isEmpty { return images > 0 ? "[image]" : nil }
        if let command = slashCommand(trimmed) { return command }
        // Output a slash command printed, and the notes Claude Code wraps in tags for the
        // model, are not things anyone said.
        if trimmed.hasPrefix("<local-command") || trimmed.hasPrefix("<system-reminder")
            || interruption(trimmed) != nil { return nil }
        return trimmed
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    // MARK: - Private

    private struct Fold {
        let projectPath: String
        var messages: [ChatMessage] = []
        // The assistant message for the turn in progress. A turn runs from one prompt to
        // the next, however many rounds of calls it takes, which is how the app keeps it.
        var reply: ChatMessage?

        init(projectPath: String) { self.projectPath = projectPath }

        mutating func take(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let when = ClaudeTranscriptImport.date(object["timestamp"])

            switch object["type"] as? String {
            case "user":
                guard object["isSidechain"] as? Bool != true else { return }
                if let prompt = ClaudeTranscriptImport.prompt(in: object) {
                    close()
                    messages.append(ChatMessage(role: .user, text: prompt, date: when ?? Date()))
                    return
                }
                if let note = interruptionNote(object) {
                    close()
                    messages.append(ChatMessage(role: .system, text: note, date: when ?? Date()))
                    return
                }
                guard !ClaudeTranscriptImport.isBookkeeping(object) else { return }
                for event in StreamEvent.parse(line, projectPath: projectPath) {
                    if case .toolResult(let id, let output, let isError, let exitCode) = event {
                        result(id: id, output: output, isError: isError, exitCode: exitCode, at: when)
                    }
                }

            case "assistant":
                guard object["isSidechain"] as? Bool != true else { return }
                for event in StreamEvent.parse(line, projectPath: projectPath) {
                    apply(event, at: when)
                }

            case "system":
                guard object["subtype"] as? String == "compact_boundary" else { return }
                close()
                messages.append(ChatMessage(role: .system,
                                            text: "Claude Code compacted the conversation here.",
                                            date: when ?? Date()))

            default:
                break
            }
        }

        // The same rules the runner follows when a turn streams in: text blocks are split
        // around calls so they need a gap, and calls and thoughts are stamped with how far
        // the turn had come, which is what puts them back in order when the turn is drawn.
        private mutating func apply(_ event: StreamEvent, at when: Date?) {
            switch event {
            case .text(let text):
                var message = current(at: when)
                if !message.text.isEmpty { message.text += "\n\n" }
                message.text += text
                reply = message
            case .thinking(let text):
                var message = current(at: when)
                var thought = ThinkingSegment(text: text)
                thought.textOffset = message.text.count
                thought.toolOffset = message.tools.count
                message.thinking = (message.thinking ?? []) + [thought]
                reply = message
            case .toolUse(let tool):
                var message = current(at: when)
                var placed = tool
                placed.textOffset = message.text.count
                placed.startedAt = when
                message.tools.append(placed)
                reply = message
            default:
                break
            }
        }

        private mutating func result(id: String, output: String, isError: Bool,
                                     exitCode: Int?, at when: Date?) {
            guard var message = reply,
                  let i = message.tools.firstIndex(where: { $0.id == id }) else { return }
            message.tools[i].result = output
            message.tools[i].isError = isError
            message.tools[i].exitCode = exitCode
            message.tools[i].finishedAt = when
            reply = message
        }

        private mutating func current(at when: Date?) -> ChatMessage {
            reply ?? ChatMessage(role: .assistant, date: when ?? Date())
        }

        private mutating func close() {
            guard var message = reply else { return }
            reply = nil
            // A call whose result never made it into the file, because the turn was cut
            // short, is over all the same. Left without a result it would spin forever.
            for i in message.tools.indices where message.tools[i].result == nil {
                message.tools[i].result = ""
            }
            if !message.isEmpty { messages.append(message) }
        }

        mutating func finish() -> [ChatMessage] {
            close()
            return messages
        }

        private func interruptionNote(_ object: [String: Any]) -> String? {
            guard let message = object["message"] as? [String: Any] else { return nil }
            let text: String
            switch message["content"] {
            case let string as String:
                text = string
            case let blocks as [Any]:
                text = blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }
                    .joined(separator: "\n")
            default:
                return nil
            }
            return ClaudeTranscriptImport.interruption(text.trimmed)
        }
    }

    // Records Claude Code writes for itself or for the model rather than as part of the
    // conversation: the caveat before a command's output, a skill's instructions, the
    // summary that replaces a compacted conversation.
    private static func isBookkeeping(_ object: [String: Any]) -> Bool {
        object["isMeta"] as? Bool == true
            || object["isSidechain"] as? Bool == true
            || object["isCompactSummary"] as? Bool == true
            || object["isVisibleInTranscriptOnly"] as? Bool == true
    }

    // "[Request interrupted by user]" and its variants, said as what happened.
    private static func interruption(_ text: String) -> String? {
        guard text.hasPrefix("[Request interrupted by user") else { return nil }
        return "Interrupted."
    }

    // A slash command is written as tags. It reads back as what was typed: "/rename notes".
    private static func slashCommand(_ text: String) -> String? {
        guard let name = tag("command-name", in: text) else { return nil }
        let arguments = tag("command-args", in: text) ?? ""
        let command = name.hasPrefix("/") ? name : "/" + name
        return arguments.isBlank ? command : command + " " + arguments.trimmed
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
}
