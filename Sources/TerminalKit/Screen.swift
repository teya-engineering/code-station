// The terminal's size in character cells.
public struct TerminalSize: Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

// Paints frames. A frame is one string per row, already cut to the screen's width by
// whoever drew it, with any SGR styling inline. Only rows that differ from the last
// frame are rewritten, and the whole frame goes out as one synchronized update (DEC
// mode 2026; terminals without it ignore the markers). Pure: it returns the bytes to
// write, so it is tested without a tty.
public struct Screen: Sendable {
    public struct Cursor: Equatable, Sendable {
        public var row: Int
        public var col: Int

        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
    }

    private var previous: [String]?
    private var size: TerminalSize?

    public init() {}

    public mutating func render(_ lines: [String], size: TerminalSize,
                                cursor: Cursor? = nil) -> String {
        let rows = (0..<max(0, size.rows)).map { $0 < lines.count ? lines[$0] : "" }
        var out = "\u{1B}[?2026h"
        if size != self.size || previous == nil {
            // A new size reflows whatever the terminal kept, so nothing on it can be
            // trusted.
            out += "\u{1B}[2J"
            previous = nil
            self.size = size
        }
        for (index, row) in rows.enumerated() where previous?[index] != row {
            out += "\u{1B}[\(index + 1);1H\u{1B}[0m" + row + "\u{1B}[0m\u{1B}[K"
        }
        previous = rows
        if let cursor {
            out += "\u{1B}[\(cursor.row + 1);\(cursor.col + 1)H\u{1B}[?25h"
        } else {
            out += "\u{1B}[?25l"
        }
        return out + "\u{1B}[?2026l"
    }

    // The next frame is painted whole, for when something else wrote to the terminal.
    public mutating func invalidate() {
        previous = nil
    }
}
