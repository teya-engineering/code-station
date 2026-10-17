import Foundation

// A trace written out for an agent to read: one line per span, indented under its caller,
// with the critical path and the failures marked. A large trace is cut down to what a
// summary rests on, every failure, the critical path and the slowest spans, along with
// the callers that place them, and says how much was left out.
enum TraceCondenser {
    static let spanCap = 300

    static func text(_ trace: Trace, environment: String, cap: Int = spanCap) -> String {
        let kept = keptIDs(trace, cap: cap)
        var lines = [
            "Trace \(trace.traceID) in \(environment): \(counted(trace.rows.count, "span")) across \(counted(trace.services.count, "service")), \(Trace.durationText(trace.durationNanos)) end to end, \(trace.errorCount) failed.",
            "Spans, each indented under its caller. * marks the critical path, ! a failed span.",
        ]
        for row in trace.rows where kept.contains(row.id) {
            let span = row.span
            let mark = (trace.criticalPath.contains(span.id) ? "*" : " ")
                + (span.isError ? "!" : " ")
            var line = String(repeating: "  ", count: row.depth)
                + "\(mark) \(span.service) \(span.operation) \(Trace.durationText(span.durationNanos))"
            if span.isError, let message = span.statusMessage {
                line += " - " + oneLine(message)
            }
            lines.append(line)
        }
        let left = trace.rows.count - kept.count
        if left > 0 {
            lines.append("(\(counted(left, "span")) left out. The critical path, failed spans and the slowest spans are kept, in that order.)")
        }
        let unlisted = failureGroups(trace.rows.filter { $0.span.isError && !kept.contains($0.id) })
        if !unlisted.isEmpty {
            lines.append("Failed spans not listed above:")
            lines += unlisted.prefix(20).map { "- \($0.count) × \($0.label)" }
            if unlisted.count > 20 {
                let rest = unlisted.dropFirst(20).reduce(0) { $0 + $1.count }
                lines.append("- \(counted(rest, "more failed span")) of \(unlisted.count - 20) other kinds")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Failures counted by where they happened and what they said, most frequent first, so
    // a retry storm reads as one line rather than a thousand.
    private static func failureGroups(_ rows: [Trace.Row]) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in rows {
            let span = row.span
            var label = "\(span.service) \(span.operation)"
            if let message = span.statusMessage { label += " - " + oneLine(message) }
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    static func keptIDs(_ trace: Trace, cap: Int) -> Set<String> {
        guard trace.rows.count > cap else { return Set(trace.rows.map(\.id)) }
        var parents: [String: String?] = [:]
        for row in trace.rows { parents[row.id] = row.span.parentID }
        var kept = Set<String>()

        // A span and the callers above it that are not kept yet.
        func chain(_ id: String) -> [String] {
            var result: [String] = []
            var current: String? = id
            while let id = current, parents.keys.contains(id), !kept.contains(id),
                  !result.contains(id) {
                result.append(id)
                current = parents[id] ?? nil
            }
            return result
        }

        // Each span comes with its callers, and only while the whole chain still fits, so
        // the cap holds however many spans failed.
        func keep(_ id: String) {
            let more = chain(id)
            if kept.count + more.count <= cap { kept.formUnion(more) }
        }
        let critical = trace.rows.filter { trace.criticalPath.contains($0.id) }
        for row in critical where kept.count < cap { keep(row.id) }
        for row in trace.rows where row.span.isError && kept.count < cap { keep(row.id) }
        let slowest = trace.rows.sorted { $0.span.durationNanos > $1.span.durationNanos }
        for row in slowest where kept.count < cap { keep(row.id) }
        return kept
    }

    private static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
    }
}
