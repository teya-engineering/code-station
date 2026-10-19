import Foundation

// A diff laid out in two columns: the old version on the left, the new on the right, and
// the number each line carries in its own version. The side-by-side view draws it and the
// review comments place themselves by it, so the two always agree on a line's number.
public struct DiffComparisonRow: Identifiable, Sendable {
    public let id: Int
    public var left: DiffLine?
    public var right: DiffLine?
    public var oldNumber: Int?
    public var newNumber: Int?

    public static func align(_ lines: [DiffLine]) -> [Self] {
        var rows: [Self] = []
        var old = 1
        var new = 1
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .deletion || line.kind == .addition {
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while index < lines.count && (lines[index].kind == .deletion || lines[index].kind == .addition) {
                    if lines[index].kind == .deletion { removed.append(lines[index]) }
                    else { added.append(lines[index]) }
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    let left = offset < removed.count ? removed[offset] : nil
                    let right = offset < added.count ? added[offset] : nil
                    rows.append(Self(id: rows.count, left: left, right: right,
                                     oldNumber: left == nil ? nil : old, newNumber: right == nil ? nil : new))
                    if left != nil { old += 1 }
                    if right != nil { new += 1 }
                }
                continue
            }
            if line.kind == .hunk {
                let parts = line.text.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? old
                    new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? new
                }
            }
            if line.kind == .gap, let gap = line.gap {
                old += gap.count ?? 0
                new = gap.start + (gap.count ?? 0)
            }
            let numbered = line.kind == .context
            rows.append(Self(id: rows.count, left: line, right: line,
                             oldNumber: numbered ? old : nil, newNumber: numbered ? new : nil))
            if numbered { old += 1; new += 1 }
            index += 1
        }
        return rows
    }
}
