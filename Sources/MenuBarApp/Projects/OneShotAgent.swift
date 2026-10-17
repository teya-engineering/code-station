import Foundation

// A throwaway, non-interactive run of a session's CLI that answers one prompt and is gone.
// It never resumes the session, so what it is asked never reaches the conversation.
enum OneShotAgent {
    // Nil whenever anything at all goes wrong. Nothing depends on this answering, and a
    // failure here must never reach the session it was asked about.
    static func read(agent: AgentKind, at path: String, arguments: [String], searchPath: String,
                     workingDirectory: String, timeout: Duration,
                     purpose: String = "one-off") async -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath

        // A line handler keeps stdin open for replies. Codex drains stdin before
        // starting even with a prompt argument, so collect its output after exit.
        guard let output = try? await CommandRunner.run(
            executable: path,
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            environment: environment,
            timeout: timeout,
            outputByteLimit: 262_144
        ) else {
            SessionLog.note("\(agent.command) \(purpose) command did not complete")
            return nil
        }
        guard output.succeeded, !output.outputTruncated else {
            SessionLog.note("\(agent.command) \(purpose) failed status=\(output.status) "
                            + "truncated=\(output.outputTruncated)")
            return nil
        }
        return collected(output.output.split(separator: "\n").map(String.init), agent: agent)
    }

    // What a run's output lines come to, read the way `read` reads them.
    static func collected(_ lines: [String], agent: AgentKind) -> String? {
        let collector = Collector(agent: agent)
        for line in lines { _ = collector.receive(line) }
        let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // The three CLIs answer in three dialects, all of which the app already reads, so the
    // run is folded onto the same events a turn produces and the text is taken off those.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let agent: AgentKind
        private let copilot = CopilotStream()
        private var parts: [String] = []
        // `claude -p --output-format json` prints a single result object and no text
        // events, so its answer is the result's own text.
        private var result: String?

        init(agent: AgentKind) { self.agent = agent }

        var text: String {
            lock.withLock { parts.isEmpty ? result ?? "" : parts.joined(separator: " ") }
        }

        func receive(_ line: String) -> CommandRunner.OutputLineAction {
            let events = switch agent {
            case .claudeCode: StreamEvent.parse(line)
            case .codex: StreamEvent.parseCodex(line)
            case .copilot: copilot.parse(line)
            }
            lock.withLock {
                for event in events {
                    switch event {
                    case .text(let text): parts.append(text)
                    case .finished(isError: false, message: let message?): result = message
                    default: break
                    }
                }
            }
            return .none
        }
    }
}
