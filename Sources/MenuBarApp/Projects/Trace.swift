import Foundation

// One request's spans as Tempo keeps them, put in the order a waterfall draws them: each
// span under the one that called it, siblings by when they started.
struct Trace: Equatable, Sendable {
    struct Attribute: Equatable, Sendable {
        let key: String
        let value: String
    }

    struct Event: Equatable, Sendable {
        let name: String
        // From the start of the span it happened in.
        let offsetNanos: Int64
        let attributes: [Attribute]
    }

    struct Span: Identifiable, Equatable, Sendable {
        let id: String
        let parentID: String?
        let service: String
        let operation: String
        let kind: String
        let startNanos: Int64
        let durationNanos: Int64
        let isError: Bool
        let statusMessage: String?
        let attributes: [Attribute]
        let resourceAttributes: [Attribute]
        let events: [Event]

        var endNanos: Int64 { startNanos + durationNanos }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let span: Span
        let depth: Int
        let hasChildren: Bool
        // The span names a parent the trace does not hold, so it is drawn at the top level
        // rather than lost.
        let parentMissing: Bool

        var id: String { span.id }
    }

    let traceID: String
    let rows: [Row]
    // In the order they first appear down the waterfall, which is also the order their
    // colours are handed out in.
    let services: [String]
    let criticalPath: Set<String>
    let startNanos: Int64
    let endNanos: Int64

    var spans: [Span] { rows.map(\.span) }
    var root: Span? { rows.first?.span }
    var durationNanos: Int64 { endNanos - startNanos }
    var errorCount: Int { rows.filter(\.span.isError).count }

    init(traceID: String, spans: [Span]) {
        var seen = Set<String>()
        let unique = spans.filter { seen.insert($0.id).inserted }
        let ids = Set(unique.map(\.id))
        var children: [String: [Span]] = [:]
        for span in unique {
            if let parent = span.parentID, parent != span.id, ids.contains(parent) {
                children[parent, default: []].append(span)
            }
        }
        for key in children.keys { children[key]?.sort(by: Self.earlier) }

        var rows: [Row] = []
        var placed = Set<String>()
        // Depth first without recursion, so a very deep trace cannot run out of stack.
        func walk(from top: Span) {
            var stack: [(Span, Int)] = [(top, 0)]
            while let (span, depth) = stack.popLast() {
                guard placed.insert(span.id).inserted else { continue }
                let kids = (children[span.id] ?? []).filter { !placed.contains($0.id) }
                rows.append(Row(span: span, depth: depth, hasChildren: !kids.isEmpty,
                                parentMissing: depth == 0 && span.parentID != nil))
                stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
            }
        }
        let tops = unique.filter { span in
            guard let parent = span.parentID, parent != span.id else { return true }
            return !ids.contains(parent)
        }
        for top in tops.sorted(by: Self.earlier) { walk(from: top) }
        // Spans whose parents name each other in a circle have no top to hang from. They
        // are drawn anyway, each loop from its earliest span.
        for span in unique.sorted(by: Self.earlier) where !placed.contains(span.id) {
            walk(from: span)
        }

        var services: [String] = []
        for row in rows where !services.contains(row.span.service) {
            services.append(row.span.service)
        }

        // Where the time went: from the root, always into the child that finished last.
        var path = Set<String>()
        var current = rows.first?.span
        while let span = current, path.insert(span.id).inserted {
            current = children[span.id]?.max { a, b in
                a.endNanos != b.endNanos ? a.endNanos < b.endNanos : a.id > b.id
            }
        }

        self.traceID = traceID
        self.rows = rows
        self.services = services
        self.criticalPath = path
        startNanos = unique.map(\.startNanos).min() ?? 0
        endNanos = unique.map(\.endNanos).max() ?? 0
    }

    private static func earlier(_ a: Span, _ b: Span) -> Bool {
        a.startNanos != b.startNanos ? a.startNanos < b.startNanos : a.id < b.id
    }

    // The spans folded when a trace first opens: everything with spans below it, except the
    // trace's root and the callers on the way down to each failed span, so every failure
    // shows without unfolding and a long trace does not open thousands of rows deep. Spans
    // whose callers are missing hang at the top too, and fold like the rest.
    var initiallyFolded: Set<String> {
        var open = Set(rows.prefix(1).map(\.id))
        // The rows come depth first, so the chain of callers above a row is a stack.
        var callers: [Row] = []
        for row in rows {
            while let last = callers.last, last.depth >= row.depth { callers.removeLast() }
            if row.span.isError { open.formUnion(callers.map(\.id)) }
            callers.append(row)
        }
        return Set(rows.filter { $0.hasChildren && !open.contains($0.id) }.map(\.id))
    }

    // How many spans sit below each span, to say what a fold hides.
    var descendantCounts: [String: Int] {
        var counts: [String: Int] = [:]
        var callers: [(id: String, depth: Int, index: Int)] = []
        for (index, row) in rows.enumerated() {
            while let last = callers.last, last.depth >= row.depth {
                counts[last.id] = index - last.index - 1
                callers.removeLast()
            }
            callers.append((row.id, row.depth, index))
        }
        for caller in callers { counts[caller.id] = rows.count - caller.index - 1 }
        return counts
    }

    // The rows still showing once the given spans are folded: everything beneath a folded
    // span is hidden, the span itself stays.
    func visibleRows(collapsed: Set<String>) -> [Row] {
        var shown: [Row] = []
        var hiddenBelow: Int?
        for row in rows {
            if let depth = hiddenBelow {
                if row.depth > depth { continue }
                hiddenBelow = nil
            }
            shown.append(row)
            if collapsed.contains(row.id) { hiddenBelow = row.depth }
        }
        return shown
    }

    // Where a span's bar sits on the trace's own time axis, as fractions of its width. A
    // span too short to see still gets a sliver.
    func bar(for span: Span, minimumWidth: Double = 0.002) -> (offset: Double, width: Double) {
        let total = Double(max(durationNanos, 1))
        let offset = min(max(Double(span.startNanos - startNanos) / total, 0), 1)
        let width = min(max(Double(span.durationNanos) / total, minimumWidth),
                        max(1 - offset, minimumWidth))
        return (offset, width)
    }

    // 850µs, 4.2ms, 412ms, 1.24s: as few digits as still tell two spans apart.
    static func durationText(_ nanos: Int64) -> String {
        if abs(nanos) < 1_000_000 { return "\(nanos / 1_000)µs" }
        let millis = Double(nanos) / 1_000_000
        if abs(millis) < 10 { return String(format: "%.1fms", millis) }
        if abs(millis) < 1_000 { return "\(Int(millis.rounded()))ms" }
        return String(format: "%.2fs", millis / 1_000)
    }
}
