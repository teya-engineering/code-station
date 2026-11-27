import Foundation
import Synchronization

// A throwaway, non-interactive run of a session's CLI that answers one prompt and is gone.
// It never resumes the session, so what it is asked never reaches the conversation.
enum OneShotAgent {
    // Nil whenever anything at all goes wrong. Nothing depends on this answering, and a
    // failure here must never reach the session it was asked about.
    static func read(agent: AgentKind, at path: String, arguments: [String], searchPath: String,
                     workingDirectory: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     timeout: Duration, purpose: String = "one-off") async -> String? {
        var environment = environment
        environment["PATH"] = searchPath

        // A line handler keeps stdin open for replies. Codex drains stdin before
        // starting even with a prompt argument, so collect its output after exit.
        let output: CommandRunner.Output
        do {
            output = try await CommandRunner.run(
                executable: path,
                arguments: arguments,
                currentDirectory: URL(fileURLWithPath: workingDirectory),
                environment: environment,
                timeout: timeout,
                outputByteLimit: 262_144
            )
        } catch CommandRunner.RunError.timedOut {
            SessionLog.note("\(agent.command) \(purpose) command timed out")
            return nil
        } catch {
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
    private final class Collector: Sendable {
        private struct Answer {
            var parts: [String] = []
            // `claude -p --output-format json` prints a single result object and no text
            // events, so its answer is the result's own text.
            var result: String?
        }

        private let parser: AgentStreamParser
        private let answer = Mutex(Answer())

        init(agent: AgentKind) { parser = AgentStreamParser(agent: agent) }

        var text: String {
            answer.withLock { $0.parts.isEmpty ? $0.result ?? "" : $0.parts.joined(separator: " ") }
        }

        func receive(_ line: String) -> CommandRunner.OutputLineAction {
            let events = parser.parse(line)
            answer.withLock { answer in
                for event in events {
                    switch event {
                    case .text(let text): answer.parts.append(text)
                    case .finished(isError: false, message: let message?): answer.result = message
                    default: break
                    }
                }
            }
            return .none
        }
    }
}
