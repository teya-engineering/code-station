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

    // A question with no tools and no MCP servers, on a quick model where the CLI has
    // one. Codex merges an empty server table with the person's own config, so each
    // enabled server has to be switched off by name for the run. Kiro's saved rules
    // still allow what they allow, so it runs under a throwaway profile with no tools.
    static func ask(agent: AgentKind, at path: String, searchPath: String,
                    workingDirectory: String, prompt: String, model: String? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    timeout: Duration, purpose: String) async -> String? {
        var disabledMCPServers: [DisabledMCPServer] = []
        if agent == .codex {
            guard let servers = try? await CodexCodeManager.enabledServers(
                at: path, searchPath: searchPath, in: workingDirectory, timeout: .seconds(5)) else {
                SessionLog.note("codex \(purpose) could not list MCP servers")
                return nil
            }
            disabledMCPServers = servers
        }
        var arguments = PromptSuggestion.arguments(for: agent, prompt: prompt, model: model,
                                                   disabledMCPServers: disabledMCPServers)
        var kiroProfile: KiroReviewProfile?
        if agent == .kiro {
            guard let profile = try? KiroReviewProfile(environment: environment, readsFiles: false) else {
                SessionLog.note("kiro \(purpose) could not create its profile")
                return nil
            }
            kiroProfile = profile
            arguments.insert(contentsOf: ["--agent", profile.name], at: 1)
        }
        defer { kiroProfile?.remove() }
        return await read(
            agent: agent, at: path, arguments: arguments,
            searchPath: searchPath, workingDirectory: workingDirectory, environment: environment,
            timeout: timeout, purpose: purpose)
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
