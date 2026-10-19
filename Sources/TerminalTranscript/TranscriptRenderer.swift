import CodeStationCore

// Draws a session's messages as terminal lines at a width. Pure: the same messages and
// width always give the same lines, so it is tested line by line, and a front end can
// cache a message's lines until the message or the width changes.
//
// - A prompt is marked "› " and its lines hang under it.
// - Prose is wrapped at words; a word wider than the line is broken.
// - Thinking is dimmed behind a "│ " rule.
// - A tool call is one line: how it went ("●" done, "○" running, "✗" failed), the core's
//   one-line label for it, and the lines it added and removed. Cut, never wrapped.
// - Blocks are separated by a blank line, and so are messages.
//
// - Prose is markdown: headings, lists, quotes, tables, emphasis, inline code, links, and
//   fenced code highlighted by its language (see TerminalMarkdown).
// - A tool call named in `expanded` is opened: under its line come the command it ran,
//   the diff it made or what came back. The front end holds which calls are open; the
//   line source on every line is what lets it find the call or message under a line.
public enum TranscriptRenderer {

    // Every message, with a blank line between one and the next.
    public static func lines(for messages: [RemoteMessage], width: Int,
                             expanded: Set<String> = []) -> [StyledLine] {
        var out: [StyledLine] = []
        for (index, message) in messages.enumerated() {
            if index > 0 { out.append(StyledLine()) }
            out += lines(for: message, width: width, expanded: expanded)
        }
        return out
    }

    // One message's lines, with no blank line before or after.
    public static func lines(for message: RemoteMessage, width: Int,
                             expanded: Set<String> = []) -> [StyledLine] {
        let width = max(width, 1)
        let source = LineSource(messageID: message.id)
        switch message.role {
        case "user":
            var out = hanging(message.text, marker: Span("› ", .userMarker), indent: "  ",
                              style: .user, width: width, source: source)
            for name in message.attachments {
                let text = TerminalColumns.fit("[\(name)]", to: max(width - 2, 1))
                out.append(StyledLine(width > 2 ? [Span("  "), Span(text, .notice)] : [Span(text, .notice)],
                                      source: source))
            }
            return out
        case "assistant":
            let blocks = message.blocks.isEmpty && !message.text.isEmpty
                ? [RemoteBlock(kind: "prose", text: message.text)]
                : message.blocks
            var out: [StyledLine] = []
            for (index, block) in blocks.enumerated() {
                let drawn = lines(for: block, width: width, expanded: expanded,
                                  source: LineSource(messageID: message.id, block: index))
                guard !drawn.isEmpty else { continue }
                if !out.isEmpty { out.append(StyledLine()) }
                out += drawn
            }
            return out
        default:
            return wrapped(message.text, style: .notice, width: width, source: source)
        }
    }

    private static func lines(for block: RemoteBlock, width: Int, expanded: Set<String>,
                              source: LineSource) -> [StyledLine] {
        switch block.kind {
        case "prose":
            return TerminalMarkdown.lines(block.text ?? "", width: width, source: source)
        case "thinking":
            return hanging(block.text ?? "", marker: Span("│ ", .thinking), indent: "│ ",
                           indentStyle: .thinking, style: .thinking, width: width, source: source)
        case "tools":
            return (block.tools ?? []).flatMap { tool in
                var toolSource = source
                toolSource.toolID = tool.id
                let line = summary(of: tool, width: width, source: toolSource)
                guard expanded.contains(tool.id) else { return [line] }
                return [line] + details(of: tool, width: width).map { StyledLine($0.spans, source: toolSource) }
            }
        default:
            return []
        }
    }

    // MARK: - Tool calls

    private static func summary(of tool: RemoteTool, width: Int, source: LineSource) -> StyledLine {
        let marker: Span = tool.isError ? Span("✗ ", .toolError)
            : tool.isRunning ? Span("○ ", .toolRunning)
            : Span("● ", .tool)
        let label = ToolPresentation.label(verb: tool.name, argument: tool.argument)
        var counts: [Span] = []
        if let added = tool.added, added > 0 { counts.append(Span(" +\(added)", .added)) }
        if let removed = tool.removed, removed > 0 { counts.append(Span(" -\(removed)", .removed)) }

        let markerWidth = TerminalColumns.width(of: marker.text)
        let countsWidth = counts.reduce(0) { $0 + TerminalColumns.width(of: $1.text) }
        // The label gives way first, then the counts, then the marker.
        if width - markerWidth - countsWidth >= 2 {
            let fitted = TerminalColumns.fit(label, to: width - markerWidth - countsWidth)
            return StyledLine([marker, Span(fitted, .tool)] + counts, source: source)
        }
        if width - markerWidth >= 1 {
            return StyledLine([marker, Span(TerminalColumns.fit(label, to: width - markerWidth), .tool)],
                              source: source)
        }
        return StyledLine([Span(TerminalColumns.fit(marker.text + label, to: width), .tool)], source: source)
    }

    // How many lines of what a call returned an open call shows.
    public static let outputLimit = 40

    // What an open call did, two columns in: the command it ran, then the diff it made,
    // or else what came back. Output keeps its spacing and is cut at the width.
    private static func details(of tool: RemoteTool, width: Int) -> [StyledText] {
        let indent = width > 4 ? 2 : 0
        let room = width - indent
        let presentation = ToolPresentation(
            tool: ToolUse(id: tool.id, name: tool.name, input: tool.input, result: tool.result,
                          isError: tool.isError),
            projectPath: "")
        var rows: [StyledText] = []

        if let command = presentation.command, !command.isEmpty {
            let lead = room >= 4 ? StyledText("$ ", .output) : StyledText()
            let rest = StyledText(String(repeating: " ", count: TerminalColumns.width(of: lead.text)))
            let code = TerminalMarkdown.highlighted(command, language: "sh")
            for (index, row) in code.broken(width: room - TerminalColumns.width(of: lead.text)).enumerated() {
                var out = index == 0 ? lead : rest
                out.append(row.trimmingTrailingWhitespace())
                rows.append(out)
            }
        }

        for change in presentation.changes {
            if presentation.changes.count > 1 { rows += StyledText(change.name, .notice).broken(width: room) }
            for line in change.lines {
                switch line.kind {
                case .addition: rows += StyledText("+ " + line.text, .added).broken(width: room)
                case .deletion: rows += StyledText("- " + line.text, .removed).broken(width: room)
                case .context: rows += StyledText("  " + line.text, .output).broken(width: room)
                case .gap: rows.append(StyledText("⋯", .notice))
                }
            }
        }

        // An edit's input is its change, so what came back says nothing more unless it failed.
        let diffSaysItAll = presentation.diffIsTheInput && !presentation.changes.isEmpty && !tool.isError
        let result = trimmingBlankEdges(TerminalText.sanitized(tool.result ?? ""))
        if !diffSaysItAll, !result.isEmpty {
            let style: LineStyle = tool.isError ? .outputError : .output
            let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(outputLimit) {
                rows += StyledText(line, style).broken(width: room).map { $0.trimmingTrailingWhitespace() }
            }
            if lines.count > outputLimit {
                rows.append(StyledText(TerminalColumns.fit("… \(lines.count - outputLimit) more lines", to: room),
                                       .output))
            }
        } else if tool.isRunning, result.isEmpty {
            rows.append(StyledText(TerminalColumns.fit("running…", to: room), .output))
        }

        guard indent > 0 else { return rows }
        return rows.map { row in
            guard !row.isEmpty else { return row }
            var out = StyledText(String(repeating: " ", count: indent))
            out.append(row)
            return out
        }
    }

    // MARK: - Wrapping

    // Text wrapped to the width, every line in one style.
    private static func wrapped(_ text: String, style: LineStyle, width: Int,
                                source: LineSource) -> [StyledLine] {
        wrap(trimmingBlankEdges(TerminalText.sanitized(text)), width: width).map {
            StyledLine($0.isEmpty ? [] : [Span($0, style)], source: source)
        }
    }

    // Text behind a marker on its first line and an indent on the rest. A marker that
    // leaves less than two columns for text is dropped, since a wide character needs two.
    private static func hanging(_ text: String, marker: Span, indent: String,
                                indentStyle: LineStyle = .plain, style: LineStyle,
                                width: Int, source: LineSource) -> [StyledLine] {
        let markerWidth = TerminalColumns.width(of: marker.text)
        guard width - markerWidth >= 2 else {
            return wrapped(text, style: style, width: width, source: source)
        }
        return wrap(trimmingBlankEdges(TerminalText.sanitized(text)), width: width - markerWidth)
            .enumerated().map { index, line in
                let lead = index == 0 ? marker : Span(indent, indentStyle)
                return StyledLine(line.isEmpty && index > 0 ? [] : [lead] + (line.isEmpty ? [] : [Span(line, style)]),
                                  source: source)
            }
    }

    // Lines at most `width` columns wide. Breaks at spaces, keeps a paragraph's leading
    // indent on its first line, and breaks a word that is wider than a whole line. Blank
    // lines are kept.
    public static func wrap(_ text: String, width: Int) -> [String] {
        StyledText(text).wrapped(width: width).map(\.text)
    }

    // Blank lines at either end say nothing, and a block that starts with the break
    // that separated it from the last one would otherwise open with a gap.
    private static func trimmingBlankEdges(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.map { line in
            var line = line
            while line.last?.isWhitespace == true { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }
}
