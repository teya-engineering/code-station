import Foundation

// A trace handed to a diagnosis: where its spans are, which services it passed through,
// and where each of those keeps its logs. It is what lets the agent follow one request
// across Grafanas rather than search each of them blind.
struct TroubleshootTraceContext: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        let name: String
        let scope: String?
    }

    let traceID: String
    let environment: String
    let services: [Service]

    var shortID: String { String(traceID.prefix(8)) }

    var promptContext: String {
        let tempo = Grafana.serverName(scope: TraceStore.tempoScope, environment: environment)
        var lines = ["Trace context:",
                     "- Trace ID: \(traceID)",
                     "- Every span of this trace is in the Tempo datasource on \(tempo)."]
        let touched = services.map { service in
            service.scope.map {
                "\(service.name) (logs on \(Grafana.serverName(scope: $0, environment: environment)))"
            } ?? "\(service.name) (Grafana not known)"
        }
        if !touched.isEmpty {
            lines.append("- Services the trace touched: \(touched.joined(separator: "; "))")
        }
        lines.append("Fetch the trace first, then read each failing service's logs for this trace ID on that service's own Grafana.")
        return lines.joined(separator: "\n")
    }
}

enum TraceHandoff {
    static func context(trace: Trace, environment: String,
                        services: [SiteDefaults.Service]) -> TroubleshootTraceContext {
        TroubleshootTraceContext(
            traceID: trace.traceID, environment: environment,
            services: trace.services.map { name in
                let known = services.first { $0.traceName == name }
                return .init(name: known?.name ?? name, scope: known?.scope)
            })
    }

    static func problem(trace: Trace, environmentTitle: String) -> String {
        var lines = ["Investigate trace `\(trace.traceID)` in \(environmentTitle)."]
        let failed = trace.spans.filter(\.isError)
        if !failed.isEmpty {
            lines.append("Failed spans:")
            for span in failed.prefix(20) {
                lines.append("- \(span.service) \(span.operation)"
                             + (span.statusMessage.map { ": \($0)" } ?? ""))
            }
            if failed.count > 20 { lines.append("- and \(failed.count - 20) more") }
        }
        return lines.joined(separator: "\n")
    }

    static func merged(problem existing: String, with addition: String) -> String {
        existing.isBlank
            ? addition
            : existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + addition
    }
}
