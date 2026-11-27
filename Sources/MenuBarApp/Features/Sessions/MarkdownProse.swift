import SwiftUI

// Blocks that draw together in one text view. Most runs are several paragraphs; a block
// that keeps sibling views of its own stands alone in a run of one.
struct ProseRun: Identifiable, Equatable, Sendable {
    let id: Int
    let blocks: [MarkdownBlock]
}

// A run of prose as one text view, or a single block drawn on its own.
//
// A transcript is mostly paragraphs, so a text view for each block would run a long
// conversation to hundreds of them. Views are what scrolling costs: AppKit walks the
// whole view tree for tracking areas and SwiftUI walks the whole display list, on every
// frame, however little of it is on screen.
struct ProseRunView: View, Equatable {
    let run: ProseRun
    let projectPath: String
    let textScale: CGFloat

    nonisolated static func == (a: ProseRunView, b: ProseRunView) -> Bool {
        a.run == b.run && a.projectPath == b.projectPath && a.textScale == b.textScale
    }

    var body: some View {
        if run.blocks.count == 1, let block = run.blocks.first {
            MarkdownBlockView(block: block, projectPath: projectPath, textScale: textScale)
        } else {
            SelectableText(prose: MarkdownBlock.sharedProse(run.blocks))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Draws one parsed block in the transcript's type and palette.
// A streaming reply is re-parsed on every flush, but only its last block is still growing.
// Comparing the block lets SwiftUI leave the settled ones alone instead of rebuilding every
// attributed string in the answer several times a second.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let projectPath: String
    let textScale: CGFloat
    var centered = false

    private var textAlignment: TextAlignment { centered ? .center : .leading }
    private var frameAlignment: Alignment { centered ? .center : .leading }

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            paragraph(text)
        case .centered(let inner):
            MarkdownBlockView(block: MarkdownBlock(id: block.id, kind: inner),
                              projectPath: projectPath, textScale: textScale, centered: true)
        case .htmlPreview(let reference):
            HTMLPreview(reference: reference, projectPath: projectPath)
        case .heading(let level, let text):
            let heading = headingSpec(level)
            SelectableText(MarkdownBlock.displayText(text),
                               size: heading.size,
                               weight: heading.weight,
                               design: heading.design,
                               alignment: textAlignment,
                               role: .heading(level: level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .padding(.top, level <= 2 ? 6 : 2)
        case .table(let table):
            MarkdownTableView(table: table, textScale: textScale)
        case .list(let items):
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        marker(item)
                            .frame(minWidth: 14, alignment: .trailing)
                        paragraph(item.text,
                                  lineSpacing: 2,
                                  role: .listItem(depth: item.depth, marker: item.marker))
                    }
                    .padding(.leading, CGFloat(item.depth) * 16 * textScale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            SelectableText(MarkdownBlock.displayText(text),
                           size: 13,
                           secondary: true,
                           role: .quote)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.lg)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent.opacity(0.35))
                        .frame(width: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    // A paragraph that holds images renders as text runs with each image between them
    // at reading size; without any it stays one piece of text.
    @ViewBuilder private func paragraph(_ text: String,
                                        lineSpacing: CGFloat = 0,
                                        role: TranscriptTextRole = .block) -> some View {
        let parts = MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: projectPath)
        }
        if parts.contains(where: { if case .image = $0 { true } else { false } }) {
            if parts.allSatisfy({ part in
                guard case .text(let text) = part else { return true }
                return text.allSatisfy { $0.isWhitespace || "·|".contains($0) }
            }) {
                let previews = ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if case .image(let alt, let url, let attributes) = part {
                        imagePreview(url: url, label: alt, attributes: attributes)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.lg) { previews }
                        .fixedSize()
                    VStack(alignment: centered ? .center : .leading, spacing: Space.lg) { previews }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            } else {
                // Only the first piece of text carries a list item's marker. The text
                // after an image is the same item going on.
                let firstText = parts.firstIndex {
                    if case .text(let piece) = $0 { !piece.isBlank } else { false }
                }
                VStack(alignment: centered ? .center : .leading, spacing: Space.md) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        switch part {
                        case .text(let piece):
                            let trimmed = piece.trimmed
                            if !trimmed.isEmpty {
                                paragraphText(trimmed,
                                              lineSpacing: lineSpacing,
                                              role: index == firstText ? role : role.continued)
                            }
                        case .image(let alt, let url, let attributes):
                            imagePreview(url: url, label: alt, attributes: attributes)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        } else {
            paragraphText(MarkdownBlock.displayText(text), lineSpacing: lineSpacing, role: role)
        }
    }

    private func imagePreview(url: URL, label: String, attributes: MarkdownImageAttributes?) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: Space.xs) {
            InlineImageView(url: url, label: label.isEmpty ? nil : label, size: attributes)
            if !label.isEmpty, attributes?.captioned ?? true {
                Text(label)
                    .scaledText(Typography.Size.caption)
                    .multilineTextAlignment(textAlignment)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func paragraphText(_ text: String,
                               lineSpacing: CGFloat,
                               role: TranscriptTextRole) -> some View {
        SelectableText(text,
                       size: 13.5,
                       lineSpacing: lineSpacing,
                       alignment: textAlignment,
                       role: role)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    // A plain bullet is a small green disc rather than a glyph, so a list of findings
    // reads as part of the app instead of as typed punctuation. Numbers and tick boxes
    // still say what they say, so those keep their marker.
    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        if item.marker.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else if MarkdownListItem.plainBullets.contains(item.marker) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 5, height: 5)
                .offset(y: -3)
        } else {
            Text(item.marker)
                .scaledText(Typography.Size.body)
                .foregroundStyle(.secondary)
        }
    }

    // Sizes step down the way the app's own headers do: serif for the two big
    // levels, plain semibold below.
    private func headingSpec(_ level: Int) -> (size: CGFloat, weight: Font.Weight, design: Font.Design) {
        let heading = MarkdownBlock.headingStyle(level)
        return (heading.size, .semibold, heading.design == .serif ? .serif : .default)
    }
}

// Markdown drawn as a page. Fenced blocks are split out first, since the block parser
// deliberately handles prose only, and everything between the fences is parsed into
// blocks. A fence tagged as a chart, a trace or log lines is drawn rather than printed.
// The transcript and the file preview both draw with this, and differ only in
// what they hang on a code block and whether a long page is built as it scrolls.
struct MarkdownProse<Code: View>: View {
    let text: String
    let projectPath: String
    let textScale: CGFloat
    var lazy = false
    // Draws HTML blocks rather than printing their tags. See MarkdownBlock.parse.
    var html = false
    var navigable = false
    let codeBlock: (MessageSegment) -> Code

    init(text: String, projectPath: String, textScale: CGFloat, lazy: Bool = false, html: Bool = false, navigable: Bool = false,
         @ViewBuilder codeBlock: @escaping (MessageSegment) -> Code) {
        self.text = text
        self.projectPath = projectPath
        self.textScale = textScale
        self.lazy = lazy
        self.html = html
        self.navigable = navigable
        self.codeBlock = codeBlock
    }

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: Space.lg) { blocks }
        } else {
            VStack(alignment: .leading, spacing: Space.lg) { blocks }
        }
    }

    // Adjacent prose and headings share a text view. The last block is always left on
    // its own: a streaming turn rewrites it many times a second, and a shared view would
    // rebuild - and drop the selection in - every paragraph above it each time.
    private func proseRuns(_ parsed: [MarkdownBlock]) -> [ProseRun] {
        var runs: [ProseRun] = []
        var shared: [MarkdownBlock] = []

        func flush() {
            guard let first = shared.first else { return }
            runs.append(ProseRun(id: first.id, blocks: shared))
            shared = []
        }

        for (offset, block) in parsed.enumerated() {
            let isLast = offset == parsed.count - 1
            if navigable, case .heading = block.kind { flush() }
            if block.sharesATextView, !isLast, !holdsImages(block) {
                shared.append(block)
            } else {
                flush()
                runs.append(ProseRun(id: block.id, blocks: [block]))
            }
        }
        flush()
        return runs
    }

    // A paragraph with pictures in it is laid out as text around images, so it keeps the
    // views that needs. Resolving one reads the disk, so only a paragraph that could hold
    // a link is asked.
    private func holdsImages(_ block: MarkdownBlock) -> Bool {
        guard case .paragraph(let text) = block.kind, text.contains("](") else { return false }
        return MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: projectPath)
        }
        .contains { if case .image = $0 { true } else { false } }
    }

    private var blocks: some View {
        // A document drops its HTML comments first, so a fence inside one stays hidden
        // rather than splitting the comment in two.
        let segments = html
            ? MessageSegment.split(MarkdownHTML.removingComments(text))
            : MessageSegment.split(text, resuming: true)
        let document = html ? MarkdownBlock.parse(document: segments) : [:]
        return ForEach(segments) { segment in
            if segment.isChart {
                TranscriptChartBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isTrace {
                TranscriptTraceBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isLogs {
                TranscriptLogsBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isCode {
                codeBlock(segment)
                    .transition(.fadeIn)
            } else {
                let settled = segment.id != segments.last?.id
                let blocks = document[segment.id]
                    ?? (settled ? MarkdownBlock.parse(settled: segment.text) : MarkdownBlock.parse(segment.text))
                ForEach(proseRuns(blocks)) { run in
                    let prose = ProseRunView(run: run, projectPath: projectPath, textScale: textScale).equatable()
                    Group {
                        if navigable {
                            prose.id(MarkdownLocation(segment: segment.id, block: run.id))
                        } else {
                            prose
                        }
                    }
                    .transition(.fadeIn)
                }
            }
        }
    }
}

// A chart in place of the block that carried it. A chart still arriving holds its place
// rather than being drawn from half its data, and one that arrived broken says so:
// dropping it would lose the evidence the agent gathered without admitting that it had.
struct TranscriptChartBlock: View, Equatable {
    let segment: MessageSegment

    // Set once the block has been seen part way through. A chart the reader watched
    // stream in then stands complete, since its arrival was not something they did.
    @State private var streamed = false

    var body: some View {
        if segment.isOpen {
            ChartArrivingCard()
                .onAppear { streamed = true }
        } else {
            switch TranscriptChartSpec.parse(segment.text) {
            case .success(let spec):
                TranscriptChartView(spec: spec, arrives: !streamed)
            case .failure(let failure):
                ChartMissingCard(failure: failure)
            }
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.segment == rhs.segment }
}

// A whole file rendered for the preview pane. Built lazily, since a document can run to
// far more blocks than a message and only the part on screen needs drawing.
struct MarkdownDocumentView: View, Equatable {
    let text: String
    let basePath: String
    let textScale: CGFloat

    var body: some View {
        MarkdownProse(text: text, projectPath: basePath, textScale: textScale, lazy: true, html: true) {
            MarkdownCodeBlock(segment: $0)
                .equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Highlighting walks the whole block and builds an attributed string from it, so the
// segment is compared for the same reason a prose block is: a settled code block in an
// answer that is still streaming is rebuilt many times a second otherwise.
struct MarkdownCodeBlock: View, Equatable {
    let segment: MessageSegment

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let language = segment.language {
                Text(language.uppercased())
                    .scaledText(Typography.Size.micro, .semibold)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            if segment.isDeletion {
                Text("Deletes the commented lines")
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableText(code: CodeHighlight.highlight(segment.text, tag: segment.language),
                                   size: 12)
                        .padding(.trailing, 32)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldSurface(cornerRadius: Radius.card)
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let textScale: CGFloat
    // Tells the cells of this table apart from those of the next one, so a selection
    // running over both does not read as one grid.
    @State private var id = UUID()

    var body: some View {
        let columnWidths = preferredColumnWidths
        VStack(alignment: .leading, spacing: 0) {
            MarkdownTableRowLayout(preferredWidths: columnWidths) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, row: 0, header: true)
                }
            }
            .background(Theme.field)
            ForEach(table.rows.indices, id: \.self) { row in
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                MarkdownTableRowLayout(preferredWidths: columnWidths) {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, row: row + 1, header: false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .cardSurface(cornerRadius: Radius.control)
    }

    // Every row uses the same preferred widths, so columns stay aligned while wider
    // content gets more room than a short number or label.
    private func cell(_ text: String, column: Int, row: Int, header: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column)
            ? table.alignments[column] : .leading
        return SelectableText(text,
                                  size: 12.5,
                                  weight: header ? .semibold : .regular,
                                  alignment: textAlignment(alignment),
                                  role: .tableCell(table: id, row: row))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
    }

    private var preferredColumnWidths: [CGFloat] {
        table.header.indices.map { column in
            let values = [table.header[column]] + table.rows.compactMap { row in
                row.indices.contains(column) ? row[column] : nil
            }
            let longest = values.map {
                AttributedString.inlineMarkdown($0).characters.count
            }.max() ?? 0
            let contentWidth = CGFloat(longest) * 6.5 * textScale
            return min(180, max(MarkdownTableRowLayout.minimumColumnWidth, contentWidth + 20))
        }
    }

    private func textAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct MarkdownTableRowLayout: Layout {
    static let minimumColumnWidth: CGFloat = 52

    let preferredWidths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let widths = columnWidths(availableWidth: proposal.width, count: subviews.count)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let widths = columnWidths(availableWidth: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    private func columnWidths(availableWidth: CGFloat?, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let preferred = (0..<count).map { column in
            preferredWidths.indices.contains(column)
                ? max(Self.minimumColumnWidth, preferredWidths[column])
                : Self.minimumColumnWidth
        }
        guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
            return preferred
        }

        let preferredTotal = preferred.reduce(0, +)
        if availableWidth >= preferredTotal {
            let extra = (availableWidth - preferredTotal) / CGFloat(count)
            return preferred.map { $0 + extra }
        }

        let minimumTotal = Self.minimumColumnWidth * CGFloat(count)
        guard availableWidth > minimumTotal else {
            return Array(repeating: availableWidth / CGFloat(count), count: count)
        }

        let shrinkableTotal = preferredTotal - minimumTotal
        guard shrinkableTotal > 0 else {
            return Array(repeating: availableWidth / CGFloat(count), count: count)
        }
        let scale = (availableWidth - minimumTotal) / shrinkableTotal
        return preferred.map { Self.minimumColumnWidth + ($0 - Self.minimumColumnWidth) * scale }
    }
}
