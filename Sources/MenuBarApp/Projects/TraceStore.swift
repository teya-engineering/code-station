import Foundation
import Observation

// What each session's Trace tab has looked up. Kept in memory for as long as the app is
// open, like the Grafana runs: a trace is a moment's evidence, not something the session
// owns.
@MainActor
@Observable
final class TraceStore {
    // Every span of a trace lands in one Tempo, on this scope's Grafana.
    nonisolated static let tempoScope = "edge"

    // How the store reaches Grafana and the agent. The app hands it the Grafana runner
    // and the session's CLI; tests hand it fakes.
    struct Backend {
        var availability: @MainActor @Sendable (String) -> GrafanaQueryRunner.Availability
        var call: @MainActor @Sendable (String, Data, String) async throws -> MCPHTTPClient.ToolResult
        var runLogs: @MainActor @Sendable (GrafanaToolCall, String, String?) -> Void
        var summarize: @MainActor @Sendable (UUID, String) async -> String?

        static func live(grafana: GrafanaQueryRunner,
                         summarize: @escaping @MainActor @Sendable (UUID, String) async -> String?)
            -> Backend {
            Backend(availability: { grafana.availability(ofServer: $0) },
                    call: { try await grafana.callTool($0, arguments: $1, on: $2) },
                    runLogs: { call, toolID, levelField in
                        grafana.run(call, toolID: toolID, query: call.query, window: .same,
                                    levelField: levelField)
                    },
                    summarize: summarize)
        }
    }

    enum Failure: Equatable {
        case invalidID
        case unavailable(String)
        case noDatasource(server: String)
        case notFound(traceID: String, environment: TroubleshootEnvironment)
        case unreadable(String)
        case failed(String)

        var message: String {
            switch self {
            case .invalidID:
                "That is not a traceId. Paste 32 (or 16) hex characters, or a Grafana trace link."
            case .unavailable(let reason):
                reason + " Add or enable it under MCP servers to look traces up."
            case .noDatasource(let server):
                "\(server) has no Tempo datasource."
            case .notFound(let traceID, let environment):
                "No trace \(traceID) in \(TraceStore.tempoScope) \(environment.title). It may be older than Tempo keeps traces, or in another environment."
            case .unreadable:
                "Grafana answered, but not with a trace."
            case .failed(let message):
                message
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case fetching(server: String)
        case found
        case failed(Failure)
    }

    enum Summary: Equatable {
        case idle
        case running
        case done(String)
        case failed
    }

    struct Lookup: Equatable {
        var input = ""
        var environment = TroubleshootEnvironment.first()
        var phase: Phase = .idle
        var trace: Trace?
        var datasource: TraceFetcher.Datasource?
        var server: String?
        var summary: Summary = .idle
        // Where the trace on screen was found. The pills can move on to look the next one
        // up, but this trace's logs, diagnosis and chat stay with the environment it is in.
        var traceEnvironment: TroubleshootEnvironment?

        var shownEnvironment: TroubleshootEnvironment { traceEnvironment ?? environment }
    }

    struct FullTrace: Equatable {
        var isLoading = true
        var trace: Trace? = nil
        var message: String? = nil
    }

    struct SpanLogs: Equatable {
        var call: GrafanaToolCall? = nil
        var toolID: String? = nil
        var service: SiteDefaults.Service? = nil
        var message: String? = nil
    }

    private let backend: Backend
    private var lookups: [UUID: Lookup] = [:]
    private var logs: [String: SpanLogs] = [:]
    private var fullTraces: [String: FullTrace] = [:]
    @ObservationIgnored private var datasources: [String: TraceFetcher.Datasource] = [:]
    @ObservationIgnored private var requests: [UUID: UUID] = [:]
    @ObservationIgnored private var summaryRequests: [UUID: UUID] = [:]

    init(backend: Backend) {
        self.backend = backend
    }

    static func tempoServer(for environment: TroubleshootEnvironment) -> String {
        Grafana.serverName(scope: tempoScope, environment: environment.name)
    }

    static func unavailableReason(_ availability: GrafanaQueryRunner.Availability) -> String? {
        switch availability {
        case .ready: nil
        case .notConfigured(let reason), .disabled(let reason), .notLocal(let reason): reason
        }
    }

    private static func datasourceKey(_ type: String, _ server: String) -> String {
        "\(type)|\(server)"
    }

    func lookup(_ sessionID: UUID) -> Lookup { lookups[sessionID] ?? Lookup() }

    func edit(_ sessionID: UUID, _ change: (inout Lookup) -> Void) {
        var lookup = lookups[sessionID] ?? Lookup()
        change(&lookup)
        lookups[sessionID] = lookup
    }

    func find(_ sessionID: UUID) {
        let current = lookup(sessionID)
        // A new lookup makes any answer still on its way to an older one irrelevant.
        requests[sessionID] = nil
        summaryRequests[sessionID] = nil
        guard let traceID = TraceInput.traceID(from: current.input) else {
            edit(sessionID) { $0.phase = .failed(.invalidID) }
            return
        }
        let environment = current.environment
        let server = Self.tempoServer(for: environment)
        if let reason = Self.unavailableReason(backend.availability(server)) {
            edit(sessionID) { $0.phase = .failed(.unavailable(reason)) }
            return
        }
        let token = UUID()
        requests[sessionID] = token
        edit(sessionID) {
            $0.phase = .fetching(server: server)
            $0.trace = nil
            $0.datasource = nil
            $0.server = server
            $0.summary = .idle
            $0.traceEnvironment = nil
        }
        Task {
            let outcome = await fetch(traceID: traceID, server: server)
            guard requests[sessionID] == token else { return }
            edit(sessionID) { lookup in
                switch outcome {
                case .found(let trace, let datasource):
                    lookup.trace = trace
                    lookup.datasource = datasource
                    lookup.traceEnvironment = environment
                    lookup.phase = .found
                case .notFound:
                    lookup.phase = .failed(.notFound(traceID: traceID, environment: environment))
                case .noDatasource:
                    lookup.phase = .failed(.noDatasource(server: server))
                case .unreadable(let text):
                    lookup.phase = .failed(.unreadable(text))
                case .failed(let message):
                    lookup.phase = .failed(.failed(message))
                }
            }
            if case .found = outcome { summarise(sessionID) }
        }
    }

    // The Tempo datasource is asked for once per server and kept for as long as the app
    // runs, since a Grafana's datasources do not move under it.
    func fetch(traceID: String, server: String) async -> TraceFetcher.Outcome {
        let call = backend.call
        let key = Self.datasourceKey("tempo", server)
        let outcome = await TraceFetcher.fetch(traceID: traceID, datasource: datasources[key]) {
            tool, arguments in try await call(tool, arguments, server)
        }
        if case .found(_, let datasource) = outcome { datasources[key] = datasource }
        return outcome
    }

    func summarise(_ sessionID: UUID) {
        let current = lookup(sessionID)
        guard let trace = current.trace else { return }
        let prompt = TraceSummary.prompt(
            condensed: TraceCondenser.text(trace, environment: current.shownEnvironment.promptTitle))
        let token = UUID()
        summaryRequests[sessionID] = token
        edit(sessionID) { $0.summary = .running }
        let summarize = backend.summarize
        Task {
            let text = await summarize(sessionID, prompt)
            guard summaryRequests[sessionID] == token else { return }
            edit(sessionID) { $0.summary = text.map(Summary.done) ?? .failed }
        }
    }

    // Puts the trace in front of the session's agent as the start of a message, without
    // sending it, so the person finishes the question. The trace itself goes in as an
    // attached file: it shows in the composer and can be taken off like any other.
    func askInChat(_ sessionID: UUID, runner: SessionRunner,
                   attach: (String, String) -> URL? = TraceStore.attachToComposer(name:text:)) {
        let current = lookup(sessionID)
        guard let trace = current.trace else { return }
        let draft = TraceSummary.chatDraft(trace: trace, environment: current.shownEnvironment)
        let attached = runner.composer.draft(sessionID).attachments.contains { $0.name == draft.fileName }
        let file = attached ? nil : attach(draft.fileName, draft.contents)
        runner.composer.editDraft(sessionID) { composer in
            if !composer.text.contains(draft.text) {
                composer.text = composer.text.isBlank ? draft.text : composer.text + "\n\n" + draft.text
            }
            if let file { composer.attachments.append(Attachment(url: file)) }
        }
    }

    // Written where pasted text goes, under a name of its own, so a second ask about the
    // same trace finds it already attached.
    nonisolated static func attachToComposer(name: String, text: String) -> URL? {
        let url = Attachments.folder.appendingPathComponent(name)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }

    // Fills the session's Troubleshoot brief with this trace. A second click for the same
    // trace leaves the problem text alone rather than writing the failures in twice.
    func troubleshoot(_ sessionID: UUID, runner: SessionRunner, services: [SiteDefaults.Service]) {
        let current = lookup(sessionID)
        guard let trace = current.trace else { return }
        let environment = current.shownEnvironment
        let context = TraceHandoff.context(trace: trace, environment: environment.name,
                                           services: services)
        let addition = TraceHandoff.problem(trace: trace, environmentTitle: environment.title)
        runner.composer.editBrief(sessionID) { brief in
            if brief.trace?.traceID != trace.traceID {
                brief.problem = TraceHandoff.merged(problem: brief.problem, with: addition)
            }
            brief.environment = environment
            brief.trace = context
        }
    }

    func spanLogs(_ key: String) -> SpanLogs? { logs[key] }

    // Reads the span's logs once per trace, span and environment. What comes back is an
    // ordinary Grafana run, so the result view re-runs and pivots it as it would the agent's.
    // One that failed, because the server was off or did not answer, can be asked again.
    func showLogs(for span: Trace.Span, sessionID: UUID, services: [SiteDefaults.Service]) {
        let current = lookup(sessionID)
        guard let trace = current.trace else { return }
        let environment = current.shownEnvironment.name
        let key = TraceSpanLogs.toolID(traceID: trace.traceID, spanID: span.id,
                                       environment: environment)
        guard logs[key] == nil || logs[key]?.message != nil,
              case .run(let server, let query, let start, let end, let service) =
                TraceSpanLogs.plan(span: span, trace: trace, environment: environment,
                                   services: services) else { return }
        if let reason = Self.unavailableReason(backend.availability(server)) {
            logs[key] = SpanLogs(message: reason + " Add or enable it under MCP servers to read its logs here.")
            return
        }
        logs[key] = SpanLogs(service: service)
        Task {
            do {
                guard let datasource = try await datasource(type: "loki", on: server) else {
                    logs[key] = SpanLogs(message: "\(server) has no Loki datasource.")
                    return
                }
                let tool = TraceSpanLogs.toolUse(id: key, server: server,
                                                 datasourceUID: datasource.uid, query: query,
                                                 start: start, end: end)
                guard let call = GrafanaToolCall(tool: tool) else {
                    logs[key] = SpanLogs(message: "The log query could not be prepared.")
                    return
                }
                logs[key] = SpanLogs(call: call, toolID: key, service: service)
                backend.runLogs(call, key, service.levelField)
            } catch {
                logs[key] = SpanLogs(message: error.localizedDescription)
            }
        }
    }

    private func datasource(type: String, on server: String) async throws
        -> TraceFetcher.Datasource? {
        let key = Self.datasourceKey(type, server)
        if let known = datasources[key] { return known }
        let call = backend.call
        let found = try await TraceFetcher.lookUp(type: type) { tool, arguments in
            try await call(tool, arguments, server)
        }
        if let found { datasources[key] = found }
        return found
    }

    func fullTrace(_ toolID: String) -> FullTrace? { fullTraces[toolID] }

    // A trace the agent fetched that the transcript cut short, fetched again from the
    // Grafana it came from.
    func loadFull(_ toolID: String, call: TraceToolCall) {
        guard let traceID = call.traceID, fullTraces[toolID]?.isLoading != true else { return }
        if let reason = Self.unavailableReason(backend.availability(call.server)) {
            fullTraces[toolID] = FullTrace(isLoading: false, message: reason)
            return
        }
        fullTraces[toolID] = FullTrace()
        Task {
            let outcome = await fetch(traceID: traceID, server: call.server)
            fullTraces[toolID] = switch outcome {
            case .found(let trace, _):
                FullTrace(isLoading: false, trace: trace)
            case .notFound:
                FullTrace(isLoading: false, message: "No trace \(traceID) on \(call.server).")
            case .noDatasource:
                FullTrace(isLoading: false, message: "\(call.server) has no Tempo datasource.")
            case .unreadable:
                FullTrace(isLoading: false, message: "Grafana answered, but not with a trace.")
            case .failed(let message):
                FullTrace(isLoading: false, message: message)
            }
        }
    }
}
