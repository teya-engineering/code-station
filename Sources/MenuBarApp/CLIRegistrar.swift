import Foundation
import Observation

// The half of registering MCP servers with a coding agent's CLI that is the same for
// every agent: running its `mcp add` and `mcp remove` steps one at a time, and keeping
// track of which servers are being worked on and what went wrong for each. The managers
// decide the arguments and read the CLI's config back afterwards; this runs the steps.
@MainActor
@Observable
final class CLIRegistrar {
    private let command: String
    private let notFoundMessage: String

    private(set) var busy: Set<String> = []
    private(set) var bulkBusy = false
    var errors: [String: String] = [:]

    init(command: String, notFoundMessage: String) {
        self.command = command
        self.notFoundMessage = notFoundMessage
    }

    func isBusy(_ name: String) -> Bool { busy.contains(name) }

    // The environment every CLI is started with. A Finder-launched app has a minimal PATH,
    // and the CLIs start servers by name.
    nonisolated static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        return environment
    }

    // Runs the binary directly, one step at a time, then calls back so the manager can read
    // what the run left in the CLI's config. No login shell: it would source the user's
    // profile, which can spawn daemons that inherit the output pipe and keep it open,
    // hanging the read forever. Steps run in order so writes to the config never race.
    func run(_ steps: [[String]], names: [String], onFinished: @escaping @MainActor () -> Void) {
        guard let executable = ProcessManager.resolve(command) else {
            for name in names { errors[name] = notFoundMessage }
            return
        }
        for name in names { busy.insert(name); errors[name] = nil }
        if names.count > 1 { bulkBusy = true }
        Task {
            let failure = await Self.failure(running: steps, executable: executable)
            for name in names {
                busy.remove(name)
                if let failure { errors[name] = failure }
            }
            bulkBusy = false
            onFinished()
        }
    }

    // What went wrong, if anything. A failing "remove" is fine (the server may not exist
    // yet); only a failing "add" is a real error worth surfacing, and the last one wins.
    // A step that could not be run at all ends the run there.
    private nonisolated static func failure(running steps: [[String]],
                                            executable: String) async -> String? {
        var failure: String?
        for arguments in steps {
            let result: CommandRunner.Output
            do {
                result = try await CommandRunner.run(executable: executable,
                                                     arguments: arguments,
                                                     environment: environment,
                                                     timeout: .seconds(60))
            } catch {
                return error.localizedDescription
            }
            guard !result.succeeded, !arguments.contains("remove") else { continue }
            let output = [result.output, result.errorOutput]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
            failure = output.isEmpty ? "Command failed (exit \(result.status))." : output
        }
        return failure
    }
}
