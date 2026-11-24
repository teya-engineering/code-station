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
    // The tree as drawn, which can differ from what the spans claim when their parents
    // name each other in a circle.
    let parentIDs: [String: String]
    let childIDs: [String: [String]]
    // When each span had something running below it, as merged stretches of time. The
    // gaps between them are the span waiting on nothing the trace can see.
    let busy: [String: [ClosedRange<Int64>]]
    // Each service's own time: its spans' time minus what ran below them.
    let ownTime: [String: Int64]
    let failuresBelow: [String: Int]
    // Every failed span and the callers above it.
    let failurePath: Set<String>
    private let spansByID: [String: Span]

    var spans: [Span] { rows.map(\.span) }
    var root: Span? { rows.first?.span }
    var durationNanos: Int64 { endNanos - startNanos }
    var errorCount: Int { rows.count(where: \.span.isError) }

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

        var parentIDs: [String: String] = [:]
        var childIDs: [String: [String]] = [:]
        var callers: [Row] = []
        for row in rows {
            while let last = callers.last, last.depth >= row.depth { callers.removeLast() }
            if let caller = callers.last {
                parentIDs[row.id] = caller.id
                childIDs[caller.id, default: []].append(row.id)
            }
            callers.append(row)
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.span) })

        var busy: [String: [ClosedRange<Int64>]] = [:]
        var ownTime: [String: Int64] = [:]
        for row in rows {
            let stretches = (childIDs[row.id] ?? []).compactMap { byID[$0] }
                .map { $0.startNanos...$0.endNanos }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Int64>] = []
            for stretch in stretches {
                if let last = merged.last, stretch.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, stretch.upperBound)
                } else {
                    merged.append(stretch)
                }
            }
            busy[row.id] = merged
            // A child can run past its caller's end, so the busy time is held inside the span.
            let below = merged.reduce(Int64(0)) { total, stretch in
                let from = max(stretch.lowerBound, row.span.startNanos)
                let to = min(stretch.upperBound, row.span.endNanos)
                return total + max(to - from, 0)
            }
            ownTime[row.span.service, default: 0] += max(row.span.durationNanos - below, 0)
        }

        var failuresBelow: [String: Int] = [:]
        var failurePath = Set<String>()
        for row in rows.reversed() {
            failuresBelow[row.id] = (childIDs[row.id] ?? []).reduce(0) { total, child in
                total + (byID[child]?.isError == true ? 1 : 0) + (failuresBelow[child] ?? 0)
            }
        }
        for row in rows where row.span.isError {
            var current: String? = row.id
            while let id = current, failurePath.insert(id).inserted { current = parentIDs[id] }
        }

        self.traceID = traceID
        self.rows = rows
        self.services = services
        self.criticalPath = path
        self.parentIDs = parentIDs
        self.childIDs = childIDs
        self.busy = busy
        self.ownTime = ownTime
        self.failuresBelow = failuresBelow
        self.failurePath = failurePath
        spansByID = byID
        startNanos = unique.map(\.startNanos).min() ?? 0
        endNanos = unique.map(\.endNanos).max() ?? 0
    }

    var wholeWindow: ClosedRange<Int64> { startNanos...max(endNanos, startNanos + 1) }

    func span(_ id: String) -> Span? { spansByID[id] }

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

    // 850µs, 4.2ms, 412ms, 1.24s: as few digits as still tell two spans apart.
    static func durationText(_ nanos: Int64) -> String {
        if abs(nanos) < 1_000_000 { return "\(nanos / 1_000)µs" }
        let millis = Double(nanos) / 1_000_000
        if abs(millis) < 10 { return String(format: "%.1fms", millis) }
        if abs(millis) < 1_000 { return "\(Int(millis.rounded()))ms" }
        return String(format: "%.2fs", millis / 1_000)
    }
}

// What the waterfall draws once folds, views and zoom have had their say: a span on its
// own, or a run of alike spans side by side folded into one row.
extension Trace {
    struct Group: Identifiable, Equatable, Sendable {
        let parent: Span
        let spans: [Span]
        let depth: Int

        // Named by the caller and the operation, so listing one run of a caller's alike
        // spans lists every run of them.
        var key: String { parent.id + ":" + spans[0].service + ":" + spans[0].operation }
        var id: String { "g:" + key }
        var startNanos: Int64 { spans.map(\.startNanos).min() ?? 0 }
        var endNanos: Int64 { spans.map(\.endNanos).max() ?? 0 }
        var failures: [Span] { spans.filter(\.isError) }
    }

    enum DisplayRow: Identifiable, Equatable, Sendable {
        case span(Row)
        case group(Group)

        var id: String {
            switch self {
            case .span(let row): row.id
            case .group(let group): group.id
            }
        }

        var depth: Int {
            switch self {
            case .span(let row): row.depth
            case .group(let group): group.depth
            }
        }
    }

    // Three alike spans in a row are already a pattern worth one line; two read fine apart.
    static let groupThreshold = 3

    // `keep` limits the rows to those spans, and `window` to the spans that run inside it
    // or have something below them that does.
    func displayRows(collapsed: Set<String>, openGroups: Set<String> = [],
                     keep: Set<String>? = nil,
                     window: ClosedRange<Int64>? = nil) -> [DisplayRow] {
        var touches: [String: Bool] = [:]
        if let window {
            for row in rows.reversed() {
                let own = row.span.endNanos >= window.lowerBound
                    && row.span.startNanos <= window.upperBound
                touches[row.id] = own || (childIDs[row.id] ?? []).contains { touches[$0] == true }
            }
        }
        func shows(_ id: String) -> Bool {
            (keep?.contains(id) ?? true) && (window == nil || touches[id] == true)
        }

        enum Work {
            case span(Row)
            case group(Group)
        }
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var out: [DisplayRow] = []
        // Depth first without recursion, the same as the rows are built.
        var stack: [Work] = rows.filter { $0.depth == 0 }.reversed().map { .span($0) }
        while let work = stack.popLast() {
            switch work {
            case .group(let group):
                out.append(.group(group))
            case .span(let row):
                guard shows(row.id) else { continue }
                out.append(.span(row))
                guard !collapsed.contains(row.id) else { continue }
                let kids = (childIDs[row.id] ?? []).filter(shows).compactMap { rowsByID[$0] }
                var next: [Work] = []
                var index = 0
                while index < kids.count {
                    let first = kids[index]
                    var end = index
                    while end + 1 < kids.count, !first.hasChildren, !kids[end + 1].hasChildren,
                          kids[end + 1].span.operation == first.span.operation,
                          kids[end + 1].span.service == first.span.service {
                        end += 1
                    }
                    let group = Group(parent: row.span, spans: kids[index...end].map(\.span),
                                      depth: first.depth)
                    if end - index + 1 >= Self.groupThreshold, !openGroups.contains(group.key) {
                        next.append(.group(group))
                        index = end + 1
                    } else {
                        next.append(.span(first))
                        index += 1
                    }
                }
                stack.append(contentsOf: next.reversed())
            }
        }
        return out
    }

    func spanCount(in window: ClosedRange<Int64>) -> Int {
        rows.count { $0.span.endNanos >= window.lowerBound && $0.span.startNanos <= window.upperBound }
    }

    // How much of a span's own time something below it was running.
    func busyNanos(_ span: Span) -> Int64 {
        (busy[span.id] ?? []).reduce(0) { total, stretch in
            let from = max(stretch.lowerBound, span.startNanos)
            let to = min(stretch.upperBound, span.endNanos)
            return total + max(to - from, 0)
        }
    }

    // Round marks for an axis over the given stretch, about five of them, as offsets from
    // the trace's start.
    func ticks(in window: ClosedRange<Int64>) -> (step: Int64, offsets: [Int64]) {
        let from = window.lowerBound - startNanos
        let to = window.upperBound - startNanos
        let step = Self.niceStep(max(to - from, 1))
        var offsets: [Int64] = []
        var tick = (from + step - 1) / step * step
        while tick <= to {
            offsets.append(tick)
            tick += step
        }
        return (step, offsets)
    }

    static func niceStep(_ range: Int64) -> Int64 {
        let raw = Double(range) / 5
        let power = pow(10, floor(log10(raw)))
        let fraction = raw / power
        let nice: Double = fraction < 1.5 ? 1 : fraction < 3.5 ? 2 : fraction < 7.5 ? 5 : 10
        return max(Int64(nice * power), 1)
    }

    // "2 s", "250 ms", "40 µs": the step decides the unit, so the marks along one axis
    // all read in the same one.
    static func tickText(_ offset: Int64, step: Int64) -> String {
        if offset == 0 { return "0" }
        if step >= 1_000_000_000 {
            let seconds = Double(offset) / 1_000_000_000
            return (step % 1_000_000_000 == 0 ? String(Int(seconds.rounded()))
                                              : String(format: "%.1f", seconds)) + " s"
        }
        if step >= 1_000_000 {
            let millis = Double(offset) / 1_000_000
            return (step % 1_000_000 == 0 ? grouped(Int64(millis.rounded()))
                                          : String(format: "%.1f", millis)) + " ms"
        }
        return grouped(offset / 1_000) + " µs"
    }

    // "17.06 s" rather than "17.06s", for a number read on its own rather than in a column.
    static func spacedDuration(_ nanos: Int64) -> String {
        let text = durationText(nanos)
        for unit in ["µs", "ms", "s"] where text.hasSuffix(unit) {
            return String(text.dropLast(unit.count)) + " " + unit
        }
        return text
    }

    // Where something happened, counted from the trace's start. Past a second it stays in
    // milliseconds, so two moments a few milliseconds apart late in a trace still differ.
    static func offsetText(_ nanos: Int64) -> String {
        if abs(nanos) >= 1_000_000_000 { return "+" + grouped(nanos / 1_000_000) + " ms" }
        return "+" + spacedDuration(nanos)
    }

    static func grouped(_ number: Int64) -> String {
        number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_GB")))
    }

    // "POST /v1/tokens" reads as a verb and what it acts on. The verb is drawn small, so
    // the eye lands on the part that tells spans apart.
    static func verb(of operation: String) -> (verb: String?, rest: String) {
        let verbs: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS",
                                  "SELECT", "INSERT", "UPDATE", "publish", "consume", "receive"]
        guard let space = operation.firstIndex(of: " ") else { return (nil, operation) }
        let first = String(operation[..<space])
        let rest = operation[space...].trimmingCharacters(in: .whitespaces)
        guard verbs.contains(first), !rest.isEmpty else { return (nil, operation) }
        return (first.uppercased(), rest)
    }
}

extension Trace {
    // A zoom held inside the trace and never narrower than a reader can still tell apart.
    // A window that takes in the whole trace is no zoom at all, so it comes back as nil.
    // A twenty-thousandth of the trace, and never under 50µs unless the trace itself is
    // that short.
    var narrowestZoom: Int64 { max(durationNanos / 20_000, min(50_000, durationNanos / 10), 1) }

    func zoomWindow(_ from: Int64, _ to: Int64) -> ClosedRange<Int64>? {
        let narrowest = narrowestZoom
        var lower = min(from, to)
        var upper = max(from, to)
        if upper - lower < narrowest {
            let middle = lower + (upper - lower) / 2
            lower = middle - narrowest / 2
            upper = middle + narrowest / 2
        }
        lower = max(lower, startNanos)
        upper = min(upper, endNanos)
        guard lower > startNanos || upper < endNanos, upper > lower else { return nil }
        return lower...upper
    }

    // The span with a little room either side, so its edges are not on the frame.
    func zoomWindow(around span: Span) -> ClosedRange<Int64>? {
        let room = max(span.durationNanos * 15 / 100, narrowestZoom)
        return zoomWindow(span.startNanos - room, span.endNanos + room)
    }
}
