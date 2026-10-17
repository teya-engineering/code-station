import Foundation
import Observation

struct GrafanaRun: Identifiable, Equatable {
    let id = UUID()
    let query: String
    let window: GrafanaQueryWindow
    var result: GrafanaToolResult?
    var error: String?
    var capped = false
    var isRunning = true

    var chipLabel: String {
        let outcome: String
        if isRunning {
            outcome = "running"
        } else if error != nil {
            outcome = "failed"
        } else {
            let noun: String
            switch result {
            case .logs?: noun = "lines"
            case .samples?: noun = "samples"
            case .series?: noun = "series"
            case .empty?, nil: noun = "results"
            }
            outcome = "\(result?.count ?? 0) \(noun)" + (capped ? " (capped)" : "")
        }
        return "you · \(outcome) · \(window.label)"
    }
}

enum GrafanaRunNote {
    struct Line: Equatable {
        let server: String
        let query: String
        let window: String
        let count: Int
        let capped: Bool
        let failed: Bool
    }

    static func text(_ lines: [Line]) -> String? {
        guard !lines.isEmpty else { return nil }
        let items = lines.map { line in
            let outcome = line.failed ? "failed"
                : "\(line.count) lines" + (line.capped ? " (capped)" : "")
            return "- `\(line.query)` over \(line.window) on \(line.server) → \(outcome)"
        }
        return (["Since your last answer the user ran these Grafana queries themselves (counts only):"]
                + items).joined(separator: "\n")
    }
}

// Runs the queries a person asks for from a Grafana result, against the same MCP server the
// agent used. Runs live here, in memory, for as long as the app is open; the transcript
// keeps only what the agent saw.
@MainActor
@Observable
final class GrafanaQueryRunner {
    enum Availability: Equatable {
        case ready
        case notConfigured(String)
        case disabled(String)
        case notLocal(String)
    }

    private let configs: ConfigStore
    private let processes: ProcessManager
    private var store: [String: [GrafanaRun]] = [:]
    private var unreported: [String: [(server: String, runID: UUID)]] = [:]
    @ObservationIgnored private var clients: [String: MCPHTTPClient] = [:]

    init(configs: ConfigStore, processes: ProcessManager) {
        self.configs = configs
        self.processes = processes
    }

    func runs(for toolID: String) -> [GrafanaRun] { store[toolID] ?? [] }

    func availability(of call: GrafanaToolCall) -> Availability {
        availability(ofServer: call.server)
    }

    func availability(ofServer name: String) -> Availability {
        guard let server = configs.servers.first(where: { $0.name == name }) else {
            return .notConfigured("\(name) is not set up in Code Station's MCP servers.")
        }
        if server.disabled { return .disabled("\(name) is turned off in MCP servers.") }
        if server.isRemote || !server.args.isEmpty {
            return .notLocal("\(name) is not run by Code Station in HTTP mode, so queries cannot be run here.")
        }
        return .ready
    }

    // Any one tool on a Grafana server, started if it is not running yet. The Trace tab
    // uses it for datasource lookups and Tempo requests.
    func callTool(_ tool: String, arguments: Data, on serverName: String) async throws
        -> MCPHTTPClient.ToolResult {
        let client = try await client(for: serverName)
        return try await client.callTool(tool, argumentsJSON: arguments)
    }

    func grafanaURL(ofServer name: String) -> String? {
        configs.servers.first { $0.name == name }?
            .env.first { $0.key == Grafana.urlKey }?.value
    }

    func run(_ call: GrafanaToolCall, toolID: String, query: String,
             window: GrafanaQueryWindow, levelField: String?) {
        let run = GrafanaRun(query: query, window: window)
        store[toolID, default: []].append(run)
        unreported[toolID, default: []].append((call.server, run.id))
        let arguments = GrafanaQueryEdit.arguments(for: call, query: query, window: window, now: Date())
        Task {
            do {
                guard let arguments else { throw GrafanaLokiPager.Stop.failed("The query could not be prepared.") }
                let client = try await client(for: call.server)
                if call.kind == .lokiLogs {
                    let toolName = call.toolName
                    let outcome = try await GrafanaLokiPager.run(arguments: arguments, levelField: levelField) {
                        try await client.callTool(toolName, argumentsJSON: $0)
                    }
                    finish(toolID, run.id) { $0.result = outcome.result; $0.capped = outcome.capped }
                } else {
                    let reply = try await client.callTool(call.toolName, argumentsJSON: arguments)
                    guard !reply.isError, let result = GrafanaToolResult.parse(reply.text) else {
                        throw GrafanaLokiPager.Stop.failed(reply.text)
                    }
                    finish(toolID, run.id) { $0.result = result }
                }
            } catch {
                finish(toolID, run.id) { $0.error = error.localizedDescription }
            }
        }
    }

    func takeNote(forToolIDs ids: Set<String>) -> String? {
        var lines: [GrafanaRunNote.Line] = []
        for id in ids.sorted() {
            guard let pending = unreported[id] else { continue }
            for (server, runID) in pending {
                guard let run = store[id]?.first(where: { $0.id == runID }), !run.isRunning else { continue }
                lines.append(.init(server: server, query: run.query, window: run.window.label,
                                   count: run.result?.count ?? 0, capped: run.capped,
                                   failed: run.error != nil))
            }
            unreported[id] = pending.filter { item in
                store[id]?.first(where: { $0.id == item.runID })?.isRunning == true
            }
        }
        return GrafanaRunNote.text(lines)
    }

    private func finish(_ toolID: String, _ runID: UUID, _ change: (inout GrafanaRun) -> Void) {
        guard let index = store[toolID]?.firstIndex(where: { $0.id == runID }) else { return }
        change(&store[toolID]![index])
        store[toolID]![index].isRunning = false
    }

    // The server the agent's call named, started in HTTP mode if it is not running yet.
    // Clients are kept per endpoint rather than per server: ports are handed out afresh
    // each time servers start, and a client kept by name could end up talking to another
    // environment's Grafana on the port this one used to have.
    private func client(for serverName: String) async throws -> MCPHTTPClient {
        guard let server = configs.servers.first(where: { $0.name == serverName }) else {
            throw GrafanaLokiPager.Stop.failed("\(serverName) is not set up in Code Station's MCP servers.")
        }
        if !processes.state(server.id).isActive { processes.start(server) }
        if case .failed(let message) = processes.state(server.id) {
            throw GrafanaLokiPager.Stop.failed(message)
        }
        guard let address = processes.endpoint(for: server.id), let endpoint = URL(string: address) else {
            throw GrafanaLokiPager.Stop.failed("\(serverName) is not running in HTTP mode.")
        }
        if let client = clients[address] { return client }
        let client = MCPHTTPClient(endpoint: endpoint)
        let id = server.id
        let processes = processes
        try await Self.waitUntilReady(attempts: 20, delay: .milliseconds(250), failure: {
            switch await processes.state(id) {
            case .failed(let message): message
            case .stopped: "\(id) stopped while it was starting."
            case .running: nil
            }
        }, connect: { try await client.prepare() })
        clients[address] = client
        return client
    }

    // A freshly started server needs a moment to listen. Asking until it answers, and
    // stopping as soon as the process itself has failed, gives the real reason rather
    // than a refused connection.
    nonisolated static func waitUntilReady(attempts: Int, delay: Duration,
                                           failure: @Sendable () async -> String?,
                                           connect: @Sendable () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            if let message = await failure() { throw GrafanaLokiPager.Stop.failed(message) }
            do {
                try await connect()
                return
            } catch {
                lastError = error
            }
            if attempt < attempts - 1 { try await Task.sleep(for: delay) }
        }
        throw GrafanaLokiPager.Stop.failed(lastError?.localizedDescription
                                           ?? "The Grafana MCP server did not answer.")
    }
}
