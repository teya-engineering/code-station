import Foundation
import Observation
import SwiftUI

enum RunState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isActive: Bool { self == .starting || self == .running }
}

// Launches and tracks the actual mcp-grafana process for a server. Running state
// is in-memory only: nothing is running right after the app starts.
@MainActor
@Observable
final class ProcessManager {
    private var processes: [Server.ID: Process] = [:]
    private var ports: [Server.ID: Int] = [:]
    private(set) var states: [Server.ID: RunState] = [:]
    private(set) var endpoints: [Server.ID: String] = [:]
    private(set) var logs: [Server.ID: String] = [:]

    func state(_ id: Server.ID) -> RunState { states[id] ?? .stopped }

    func toggle(_ server: Server) {
        state(server.id).isActive ? stop(server.id) : start(server)
    }

    func start(_ server: Server) {
        guard let executable = Self.resolve(server.command ?? "") else {
            states[server.id] = .failed(
                "Could not find \"\(server.command ?? "")\" on PATH. Install it (go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest) or use an absolute path.")
            return
        }

        let port = nextPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // For Grafana with no transport args, run a reachable HTTP server instead of
        // an idle stdio process. Other servers run exactly as configured.
        let httpMode = server.isGrafana && server.args.isEmpty
        process.arguments = httpMode
            ? ["-t", "streamable-http", "-address", "localhost:\(port)"]
            : server.args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath
        for variable in server.env where !variable.key.isEmpty {
            env[variable.key] = variable.value
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        logs[server.id] = ""

        let id = server.id
        let manager = self
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in manager.appendLog(id, text) }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in manager.processEnded(id, code: code) }
        }

        do {
            states[id] = .starting
            try process.run()
            processes[id] = process
            ports[id] = port
            if httpMode { endpoints[id] = "http://localhost:\(port)/mcp" }
            states[id] = .running
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    func stop(_ id: Server.ID) {
        guard let process = processes[id] else {
            states[id] = .stopped
            return
        }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        cleanup(id)
        states[id] = .stopped
    }

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
    }

    func startAll(_ servers: [Server]) {
        for server in servers where !state(server.id).isActive { start(server) }
    }

    func stopAll(_ ids: [Server.ID]) {
        for id in ids where state(id).isActive { stop(id) }
    }

    func clearLog(_ id: Server.ID) { logs[id] = "" }

    func runningCount(among ids: [Server.ID]) -> Int {
        ids.filter { state($0).isActive }.count
    }

    // MARK: - Private

    private func processEnded(_ id: Server.ID, code: Int32) {
        // Ignore if we already stopped it deliberately.
        guard processes[id] != nil else { return }
        cleanup(id)
        states[id] = code == 0 ? .stopped : .failed("Exited with code \(code). See output below.")
    }

    private func cleanup(_ id: Server.ID) {
        processes[id] = nil
        ports[id] = nil
        endpoints[id] = nil
    }

    private func appendLog(_ id: Server.ID, _ text: String) {
        var current = (logs[id] ?? "") + text
        if current.count > 8000 { current = String(current.suffix(8000)) }
        logs[id] = current
    }

    private func nextPort() -> Int {
        let used = Set(ports.values)
        var port = 8000
        while used.contains(port) { port += 1 }
        return port
    }

    // MARK: - Executable resolution

    // A Finder-launched app has a minimal PATH, so search the usual install dirs too.
    private static let searchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/go/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
        return dirs
    }()

    static var searchPath: String { searchDirs.joined(separator: ":") }

    static func resolve(_ command: String) -> String? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in searchDirs {
            let path = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
