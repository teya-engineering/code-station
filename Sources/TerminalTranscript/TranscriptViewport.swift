import CodeStationCore

// The window of a transcript that fits on screen, and where it sits. Only the messages
// the window passes over are drawn, and each message's lines are kept until it changes
// or the width does, so a transcript of thousands of lines scrolls as fast as a short
// one.
//
// The window follows new output only while it is at the bottom. Scrolling up stops
// that; coming back down to the last line, or jumping to the bottom, starts it again.
public struct TranscriptViewport {
    // The top line of the window: a message and a row inside it. Rows are a message's
    // lines with the blank line that separates it from the one before.
    private struct Anchor {
        var messageID: String
        var index: Int
        var row: Int
    }

    private struct Drawn {
        var digest: RemoteMessageDigest
        var width: Int
        // The message's tool calls that were open when it was drawn.
        var open: Set<String>
        var lines: [StyledLine]
    }

    // A row of the transcript: a message, and a row of its lines as the window counts
    // them (the blank line before a message is its row 0, after the first message).
    public struct Position: Hashable, Sendable {
        public let messageID: String
        public let row: Int

        public init(messageID: String, row: Int) {
            self.messageID = messageID
            self.row = row
        }
    }

    public private(set) var isFollowing = true
    // Where each line of the last window came from, line for line.
    public private(set) var windowPositions: [Position] = []
    private var anchor: Anchor?
    private var pendingReveal: Position?
    private var pendingLines = 0
    private var pendingTop = false
    private var lastHeight = 1
    private var drawn: [String: Drawn] = [:]
    private var expanded: Set<String> = []

    public init() {}

    // MARK: - Moving

    // Positive scrolls toward newer output, negative toward older.
    public mutating func scroll(by lines: Int) {
        pendingLines += lines
    }

    // A page is the window's height less one line, kept for context.
    public mutating func scrollPage(by pages: Int) {
        pendingLines += pages * max(lastHeight - 1, 1)
    }

    public mutating func scrollToTop() {
        pendingTop = true
        pendingLines = 0
        isFollowing = false
    }

    public mutating func scrollToBottom() {
        pendingTop = false
        pendingLines = 0
        isFollowing = true
    }

    // Brings a row into the next window, a third of the way down, and stops following,
    // so what was looked for stays put while output streams in under it.
    public mutating func reveal(_ position: Position) {
        pendingReveal = position
        pendingTop = false
        pendingLines = 0
        isFollowing = false
    }

    // Every row of the transcript, drawn at `width` with the tool calls in `expanded`
    // open, where `matches` holds, top to bottom. For finding text and tool calls.
    public mutating func positions(in messages: [RemoteMessage], width: Int, expanded: Set<String> = [],
                                   where matches: (StyledLine) -> Bool) -> [Position] {
        self.expanded = expanded
        var found: [Position] = []
        for index in messages.indices {
            for (row, line) in rows(index, in: messages, width: width).enumerated() where matches(line) {
                found.append(Position(messageID: messages[index].id, row: row))
            }
        }
        return found
    }

    // MARK: - The window

    // The lines on screen, at most `height` of them, with the tool calls in `expanded`
    // open. Applies any scrolling asked for since the last window.
    public mutating func window(of messages: [RemoteMessage], width: Int, height: Int,
                                expanded: Set<String> = []) -> [StyledLine] {
        let height = max(height, 1)
        self.expanded = expanded
        lastHeight = height
        defer { pendingLines = 0; pendingTop = false; pendingReveal = nil }
        guard !messages.isEmpty else {
            anchor = nil
            isFollowing = true
            windowPositions = []
            return []
        }
        prune(keeping: messages)

        var top: (index: Int, row: Int)
        if let reveal = pendingReveal, let index = messages.firstIndex(where: { $0.id == reveal.messageID }) {
            top = move((index, reveal.row), by: -(height / 3), in: messages, width: width)
        } else if pendingTop {
            top = (0, 0)
        } else if isFollowing || anchor == nil {
            top = bottomTop(messages, width: width, height: height)
        } else {
            top = resolve(anchor!, in: messages)
        }
        if pendingLines != 0 {
            top = move(top, by: pendingLines, in: messages, width: width)
        }

        let (lines, hasMore) = gather(from: top, in: messages, width: width, height: height)
        if hasMore {
            isFollowing = false
            remember(top, in: messages)
            return lines
        }
        // The window reaches the last line, so it is at the bottom and follows from here.
        isFollowing = true
        let bottom = bottomTop(messages, width: width, height: height)
        remember(bottom, in: messages)
        return lines.count == height ? lines
            : gather(from: bottom, in: messages, width: width, height: height).lines
    }

    // MARK: - Walking the rows

    private mutating func rows(_ index: Int, in messages: [RemoteMessage], width: Int) -> [StyledLine] {
        let message = messages[index]
        let digest = RemoteTranscriptDiff.digest(of: message)
        let open = openTools(in: message)
        let lines: [StyledLine]
        if let cached = drawn[message.id], cached.width == width, cached.digest == digest, cached.open == open {
            lines = cached.lines
        } else {
            lines = TranscriptRenderer.lines(for: message, width: width, expanded: open)
            drawn[message.id] = Drawn(digest: digest, width: width, open: open, lines: lines)
        }
        return index == 0 ? lines : [StyledLine()] + lines
    }

    private func openTools(in message: RemoteMessage) -> Set<String> {
        guard !expanded.isEmpty else { return [] }
        var open: Set<String> = []
        for block in message.blocks {
            for tool in block.tools ?? [] where expanded.contains(tool.id) { open.insert(tool.id) }
        }
        return open
    }

    // Where the window's top sits when its last line is the transcript's last line.
    private mutating func bottomTop(_ messages: [RemoteMessage], width: Int,
                                    height: Int) -> (index: Int, row: Int) {
        var total = 0
        for index in messages.indices.reversed() {
            let count = rows(index, in: messages, width: width).count
            if total + count >= height { return (index, total + count - height) }
            total += count
        }
        return (0, 0)
    }

    private mutating func move(_ top: (index: Int, row: Int), by lines: Int,
                               in messages: [RemoteMessage], width: Int) -> (index: Int, row: Int) {
        var (index, row) = top
        row += lines
        while row < 0 {
            guard index > 0 else { return (0, 0) }
            index -= 1
            row += rows(index, in: messages, width: width).count
        }
        while row >= rows(index, in: messages, width: width).count {
            guard index < messages.count - 1 else {
                return (index, max(rows(index, in: messages, width: width).count - 1, 0))
            }
            row -= rows(index, in: messages, width: width).count
            index += 1
        }
        return (index, row)
    }

    private mutating func gather(from top: (index: Int, row: Int), in messages: [RemoteMessage],
                                 width: Int, height: Int) -> (lines: [StyledLine], hasMore: Bool) {
        var out: [StyledLine] = []
        windowPositions = []
        var index = top.index
        var row = top.row
        while index < messages.count {
            let lines = rows(index, in: messages, width: width)
            while row < lines.count {
                if out.count == height { return (out, true) }
                out.append(lines[row])
                windowPositions.append(Position(messageID: messages[index].id, row: row))
                row += 1
            }
            index += 1
            row = 0
        }
        return (out, false)
    }

    // MARK: - Remembering the place

    private mutating func remember(_ top: (index: Int, row: Int), in messages: [RemoteMessage]) {
        anchor = Anchor(messageID: messages[top.index].id, index: top.index, row: top.row)
    }

    // The anchor's message where it is now. A message that has gone leaves the window
    // where that message used to be.
    private func resolve(_ anchor: Anchor, in messages: [RemoteMessage]) -> (index: Int, row: Int) {
        if anchor.index < messages.count, messages[anchor.index].id == anchor.messageID {
            return (anchor.index, anchor.row)
        }
        if let index = messages.firstIndex(where: { $0.id == anchor.messageID }) {
            return (index, anchor.row)
        }
        return (min(anchor.index, messages.count - 1), 0)
    }

    // Drawn lines for messages that are gone are let go once they outnumber the rest.
    private mutating func prune(keeping messages: [RemoteMessage]) {
        guard drawn.count > messages.count * 2 + 64 else { return }
        let ids = Set(messages.map(\.id))
        drawn = drawn.filter { ids.contains($0.key) }
    }
}
