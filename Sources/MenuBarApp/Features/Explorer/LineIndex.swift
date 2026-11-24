import Foundation

// Character offsets where each line starts, so the gutter can name a line and the
// highlighter can find one without counting newlines from the top of the file each time.
// Offsets are UTF-16, which is the unit the text view counts in.
struct LineIndex: Equatable {
    private var starts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        var from = 0
        while from < text.length {
            let found = text.range(of: "\n", options: .literal,
                                   range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 1
            starts.append(from)
        }
        self.starts = starts
    }

    // A file that ends in a newline has an empty last line. The text view draws it, so it
    // is counted and numbered here too.
    var count: Int { starts.count }

    func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    // The line an offset falls on, clamped at both ends so a stale offset cannot trap.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // One whole line including its newline, which is the unit the highlighter works in: a
    // token can only be read from the start of the line that holds it.
    func range(of line: Int, length: Int) -> NSRange {
        guard line >= 0, line < count else { return NSRange(location: length, length: 0) }
        let from = start(of: line)
        let to = line + 1 < count ? start(of: line + 1) : length
        return NSRange(location: from, length: max(0, min(to, length) - from))
    }
}
