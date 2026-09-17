import Foundation
import SwiftUI

// The next prompt a person is likely to type, offered under the composer once a turn
// ends. Claude Code predicts one itself and reports it on the stream, so its sessions
// pay nothing for this. The other CLIs have nothing like it, so the app asks for one in
// a throwaway run that never resumes the session: keeping the question out of the
// conversation is what stops a per-turn convenience from filling the window it is meant
// to help with.
enum PromptSuggestion {
    // Deliberately narrow. A suggestion is only worth offering when it reads like
    // something a person would have typed, so anything explaining itself, hedging, or
    // answering in the agent's voice is dropped rather than tidied up.
    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = unwrapped(candidate)
        candidate = withoutLabel(candidate)
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        candidate = candidate.replacingOccurrences(of: "\u{2014}", with: "-")

        guard !candidate.isEmpty, candidate.count <= maxCharacters,
              !candidate.contains(where: \.isNewline),
              !candidate.contains("*"), !candidate.contains("#"),
              !isRefusal(candidate), !isMultipleSentences(candidate) else { return nil }

        let words = candidate.split(whereSeparator: \.isWhitespace).count
        guard words >= minWords, words <= maxWords else { return nil }
        return candidate
    }

    private static let maxCharacters = 120
    private static let minWords = 2
    private static let maxWords = 20

    // The agent wrapping its answer in a tag or a label rather than just giving it.
    private static func unwrapped(_ text: String) -> String {
        for tag in ["suggestion", "response", "output", "answer", "result"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard text.hasPrefix(open), text.hasSuffix(close) else { continue }
            return String(text.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func withoutLabel(_ text: String) -> String {
        let labels = ["suggested prompt", "suggested response", "suggested reply",
                      "suggestion", "prompt", "response", "reply", "answer", "output"]
        let lower = text.lowercased()
        for label in labels where lower.hasPrefix(label + ":") {
            return String(text.dropFirst(label.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusals = ["none", "no suggestion", "nothing to suggest", "n/a",
                        "api error", "prompt is too long", "invalid api key"]
        return refusals.contains { lower == $0 || lower.hasPrefix($0) }
    }

    // A second sentence means the agent is explaining itself rather than offering a
    // prompt. A trailing full stop is not a sentence break, so only an interior one counts.
    private static func isMultipleSentences(_ text: String) -> Bool {
        let body = text.dropLast()
        var previousWasTerminator = false
        for character in body {
            if previousWasTerminator, character == " " { return true }
            previousWasTerminator = ".!?".contains(character)
        }
        return false
    }

    // MARK: - Asking a CLI that cannot predict one itself

    static let prompt = """
    Do not use tools and do not change any files. Below is the end of a conversation between a person and a coding agent. Write the one prompt the person is most likely to type next. Write it as the person would, speaking to the agent. Use at most 15 words, one sentence, plain text, no markdown and no quotes. If nothing useful comes next, reply with only the word none. Return only the prompt.
    """

    // Enough of the end of the conversation to say what just happened, and no more. A
    // longer tail costs more on every turn without changing what comes next.
    static func conversationTail(lastPrompt: String, lastReply: String) -> String {
        """
        \(prompt)

        The person asked:
        \(trimmed(lastPrompt))

        The agent answered:
        \(trimmed(lastReply))
        """
    }

    private static func trimmed(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 2_000 else { return clean }
        return String(clean.suffix(2_000))
    }

    // The CLIs with no prediction of their own are asked on their cheapest model, since
    // the job is a sentence of plain text rather than anything needing reasoning.
    static func quickModel(for agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: "haiku"
        case .codex: nil
        case .copilot: "auto"
        }
    }

    static func arguments(for agent: AgentKind, prompt: String) -> [String] {
        switch agent {
        case .claudeCode:
            // Here for completeness. A Claude Code session reads the CLI's own prediction
            // off the stream it is already listening to, so it never pays for this.
            var arguments = ["-p", prompt, "--output-format", "json",
                             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            if let model = quickModel(for: agent) { arguments += ["--model", model] }
            return arguments

        case .codex:
            // Read-only with approvals off, so a run that ignores the instruction and
            // reaches for a tool is stopped by the sandbox rather than by the prompt.
            var arguments = ["exec", "--json", "--skip-git-repo-check",
                             "--sandbox", "read-only",
                             "-c", #"approval_policy="never""#]
            if let model = quickModel(for: agent) { arguments += ["-m", model] }
            arguments.append(prompt)
            return arguments

        case .copilot:
            var arguments = ["-p", prompt, "--output-format", "json",
                             "--no-ask-user", "--disable-builtin-mcps", "--log-level", "none"]
            if let model = quickModel(for: agent) { arguments += ["--model", model] }
            return arguments
        }
    }

    // Nil whenever anything at all goes wrong. Nothing depends on this answering, and a
    // failure here must never reach the session it was asked about.
    static func read(agent: AgentKind, at path: String, searchPath: String,
                     workingDirectory: String, prompt: String) async -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath

        let collected = Collector(agent: agent)
        guard let output = try? await CommandRunner.run(
            executable: path,
            arguments: arguments(for: agent, prompt: prompt),
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            environment: environment,
            outputLineHandler: collected.receive,
            timeout: .seconds(45),
            outputByteLimit: 262_144
        ), output.succeeded else { return nil }
        return cleaned(collected.text)
    }

    // The three CLIs answer in three dialects, all of which the app already reads, so the
    // run is folded onto the same events a turn produces and the text is taken off those.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let agent: AgentKind
        private let copilot = CopilotStream()
        private var parts: [String] = []

        init(agent: AgentKind) { self.agent = agent }

        var text: String { lock.withLock { parts.joined(separator: " ") } }

        func receive(_ line: String) -> CommandRunner.OutputLineAction {
            let events = switch agent {
            case .claudeCode: StreamEvent.parse(line)
            case .codex: StreamEvent.parseCodex(line)
            case .copilot: copilot.parse(line)
            }
            lock.withLock {
                for case .text(let text) in events { parts.append(text) }
            }
            return .none
        }
    }
}

// The prediction sits above the composer rather than inside it: the field still holds
// whatever was half-written, and taking the suggestion is a choice rather than something
// that happens to the draft on its own.
struct PromptSuggestionStrip: View {
    let suggestion: String
    let take: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: take) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(suggestion)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("Put this in the composer")
            .accessibilityLabel("Suggested next prompt: \(suggestion)")

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("Hide this suggestion")
            .accessibilityLabel("Hide this suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.field, cornerRadius: 8, border: Theme.border)
    }
}
