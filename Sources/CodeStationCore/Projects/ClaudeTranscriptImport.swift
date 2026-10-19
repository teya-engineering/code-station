import Foundation

// Turns a conversation Claude Code wrote to its own history file into the messages the
// app keeps, so a session started in the terminal reads the same as one started here.
//
// The file is a list of records, and the ones that matter have the same shape as the
// CLI's stream output, so their content goes through `StreamEvent.parse`. What the stream
// never carries is handled here: the prompts themselves (the app writes those on its own
// when it runs a turn), the records Claude Code keeps for its own bookkeeping, and the
// turns of subagents, which belong in their call rather than in the conversation.
public enum ClaudeTranscriptImport {
    public static func messages(from file: URL, projectPath: String) throws -> [ChatMessage] {
        var chain = Chain()
        try SessionHistoryLines.read(file) { chain.take($0) }
        let selected = chain.selectedLines
        var fold = Fold(projectPath: projectPath)
        var index = 0
        try SessionHistoryLines.read(file) { line in
            defer { index += 1 }
            if selected?.contains(index) != false || chain.unlinked.contains(index) { fold.take(line) }
        }
        return fold.finish()
    }

    public static func messages(fromLines lines: [String], projectPath: String = "") -> [ChatMessage] {
        var chain = Chain()
        for line in lines { chain.take(line) }
        let selected = chain.selectedLines
        var fold = Fold(projectPath: projectPath)
        for (i, line) in lines.enumerated() where selected?.contains(i) != false || chain.unlinked.contains(i) {
            fold.take(line)
        }
        return fold.finish()
    }

    // Rewinding leaves abandoned records in the log. Keep only the current branch;
    // offsets and parent IDs are enough to select it without retaining message bodies.
    private struct Chain {
        public struct Node {
            public let line: Int
            public let parent: String?
        }
        public var nodes: [String: Node] = [:]
        public var leaf: String?
        public var unlinked: Set<Int> = []
        public var index = 0
        public var hasLinks = false

        public mutating func take(_ line: String) {
            defer { index += 1 }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let id = object["uuid"] as? String else { unlinked.insert(index); return }
            hasLinks = hasLinks || object.keys.contains("parentUuid")
            let parent = object["parentUuid"] as? String ?? object["logicalParentUuid"] as? String
            nodes[id] = Node(line: index, parent: parent)
            if ["user", "assistant"].contains(object["type"] as? String ?? ""),
               object["isSidechain"] as? Bool != true, object["teamName"] as? String == nil,
               object["isMeta"] as? Bool != true { leaf = id }
        }

        public var selectedLines: Set<Int>? {
            guard hasLinks, var id = leaf else { return nil }
            var selected: Set<Int> = []
            while let node = nodes[id], selected.insert(node.line).inserted {
                guard let parent = node.parent else { break }
                id = parent
            }
            return selected
        }
    }

    // What the person typed in a user record, or nil when the record is not a prompt:
    // a tool result, a note Claude Code added for the model, or a command's output.
    public static func prompt(in object: [String: Any]) -> String? {
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

    public static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    // MARK: - Private

    private struct Fold {
        public let projectPath: String
        public var transcript = ImportedTranscript()

        public init(projectPath: String) { self.projectPath = projectPath }

        public mutating func take(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let when = ClaudeTranscriptImport.date(object["timestamp"])

            switch object["type"] as? String {
            case "user":
                guard object["isSidechain"] as? Bool != true else { return }
                if let prompt = ClaudeTranscriptImport.prompt(in: object) {
                    transcript.prompt(prompt, at: when)
                    return
                }
                if let note = interruptionNote(object) {
                    transcript.note(note, at: when)
                    return
                }
                guard !ClaudeTranscriptImport.isBookkeeping(object) else { return }
                for event in StreamEvent.parse(line, projectPath: projectPath) {
                    if case .toolResult(let id, let output, let isError, let exitCode) = event {
                        transcript.apply(.toolResult(id: id, output: output, isError: isError, exitCode: exitCode), at: when)
                    }
                }

            case "assistant":
                guard object["isSidechain"] as? Bool != true else { return }
                for event in StreamEvent.parse(line, projectPath: projectPath) {
                    transcript.apply(event, at: when)
                }

            case "system":
                guard object["subtype"] as? String == "compact_boundary" else { return }
                transcript.note("Claude Code compacted the conversation here.", at: when)

            default:
                break
            }
        }

        public mutating func finish() -> [ChatMessage] { transcript.finish() }

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
