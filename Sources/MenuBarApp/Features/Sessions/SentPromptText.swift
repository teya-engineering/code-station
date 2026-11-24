import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var sentPromptCommandNames = SlashCommandNames()
}

// The conversation shares its command names so each bubble need not read the files.
struct SentPromptCommands: ViewModifier {
    let agent: AgentKind
    let workingDirectories: [String]
    let latestPromptID: UUID?
    @State private var names = SlashCommandNames()

    func body(content: Content) -> some View {
        content
            .environment(\.sentPromptCommandNames, names)
            .task(id: [agent.rawValue, latestPromptID?.uuidString ?? ""] + workingDirectories) {
                let agent = agent
                let roots = workingDirectories
                let commands = await Task.detached {
                    AgentCommands.all(for: agent, workingDirectories: roots)
                }.value
                guard !Task.isCancelled else { return }
                names = SlashCommandNames(commands, agent: agent)
            }
    }
}

struct SentPromptText: View {
    @Environment(\.sentPromptCommandNames) private var commandNames
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(SentPrompt.segments(text)) { segment in
                if segment.isCode {
                    MarkdownCodeBlock(segment: segment)
                        .equatable()
                        .transcriptCopyButton(for: segment.text, tooltip: "Copy code", inset: 6)
                } else {
                    ForEach(Array(SentPrompt.quoteRuns(segment.text).enumerated()), id: \.offset) { offset, run in
                        // Only the first words typed open the prompt. A command anywhere
                        // after them is one the agent picks up as it reads.
                        let prose = SelectableText(
                            prose: SentPrompt.inline(run.text, commands: commandNames,
                                                     opensPrompt: segment.id == 0 && offset == 0 && !run.isQuote),
                            lineSpacing: 3, width: .hugs, linksLocalServers: false)
                            .fixedSize(horizontal: false, vertical: true)
                        if run.isQuote {
                            // The bubble can be filled with the accent, so the bar and the dimmed
                            // text take the bubble's own text colour rather than the accent.
                            prose
                                .opacity(0.75)
                                .padding(.leading, Space.lg)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(.primary.opacity(0.3))
                                        .frame(width: 3)
                                }
                        } else {
                            prose
                        }
                    }
                }
            }
        }
    }
}

enum SentPrompt {
    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // Every command the agent will act on is drawn bold in the accent, by the same rules
    // the prompt box colours them, apart from any inside code or a link.
    static func inline(_ text: String, commands: SlashCommandNames,
                       opensPrompt: Bool = true) -> AttributedString {
        let ranges = SlashQuery.highlightedRanges(in: text, caret: nil, names: commands,
                                                  opensPrompt: opensPrompt)
        let (markdown, commands) = rendering(text, locating: ranges)
        var attributed = markdown
        let rendered = String(attributed.characters)
        for match in links?.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)) ?? [] {
            guard let url = match.url, let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()),
                  let range = Range(match.range, in: rendered),
                  let start = AttributedString.Index(range.lowerBound, within: attributed),
                  let end = AttributedString.Index(range.upperBound, within: attributed),
                  attributed[start..<end].runs.allSatisfy({
                      $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false)
                  }) else { continue }
            attributed[start..<end].link = url
        }

        for command in commands {
            guard let range = Range(command, in: rendered),
                  let start = AttributedString.Index(range.lowerBound, within: attributed),
                  let end = AttributedString.Index(range.upperBound, within: attributed),
                  attributed[start..<end].runs.allSatisfy({
                      $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false)
                  }) else { continue }
            attributed[start..<end].foregroundColor = Theme.accent
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    // Markdown takes characters out as it renders, so a command found in the typed text is
    // not at the same place in what is shown. Each one is marked in the typed text with a
    // character of its own that the parser keeps as it is, and found again by that mark
    // once it renders. A command whose mark Markdown dropped, such as one in a link
    // address, is simply left plain. The marks are then taken out, leaving the rendered
    // prompt and where each command ended up in it.
    private static let marks: Range<UInt32> = 0xE000..<0xF000

    private static func rendering(_ text: String, locating ranges: [NSRange]) -> (AttributedString, [NSRange]) {
        guard !ranges.isEmpty, ranges.count <= marks.count,
              !text.unicodeScalars.contains(where: { marks.contains($0.value) }) else {
            return (.inlineMarkdown(text), [])
        }
        let marked = NSMutableString(string: text)
        for (index, range) in ranges.enumerated().reversed() {
            guard let mark = Unicode.Scalar(marks.lowerBound + UInt32(index)) else { continue }
            marked.insert(String(mark), at: range.location)
        }
        let rendered = AttributedString.inlineMarkdown(marked as String)

        // Where each mark sits once the marks before it are gone. A mark is one UTF-16 unit.
        var places: [Int: Int] = [:]
        var removed = 0
        for (offset, unit) in String(rendered.characters).utf16.enumerated() where marks.contains(UInt32(unit)) {
            places[Int(UInt32(unit) - marks.lowerBound)] = offset - removed
            removed += 1
        }
        var attributed = rendered
        while let mark = attributed.characters.firstIndex(where: {
            $0.unicodeScalars.contains { marks.contains($0.value) }
        }) {
            attributed.removeSubrange(mark..<attributed.characters.index(after: mark))
        }

        // A command that Markdown changed on the way, such as a name with underscores read
        // as emphasis, is left as it was drawn.
        let shown = String(attributed.characters) as NSString
        let typed = text as NSString
        let found = ranges.enumerated().compactMap { index, range -> NSRange? in
            guard let place = places[index] else { return nil }
            let moved = NSRange(location: place, length: range.length)
            guard NSMaxRange(moved) <= shown.length,
                  shown.substring(with: moved) == typed.substring(with: range) else { return nil }
            return moved
        }
        return (attributed, found)
    }

    struct QuoteRun: Equatable {
        let isQuote: Bool
        let text: String
    }

    // A prompt is shown as typed, apart from its Markdown quotes, which Reply writes and
    // which are drawn as quotes. Only the marker and the one space after it are taken off,
    // so quoted code keeps its indentation.
    static func quoteRuns(_ text: String) -> [QuoteRun] {
        var runs: [QuoteRun] = []
        var lines: [String] = []
        var quoting = false

        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !body.isBlank { runs.append(QuoteRun(isQuote: quoting, text: body)) }
            lines = []
        }

        for line in text.components(separatedBy: "\n") {
            let marked = line.drop(while: { $0 == " " })
            let isQuote = marked.first == ">"
            if isQuote != quoting {
                flush()
                quoting = isQuote
            }
            guard isQuote else {
                lines.append(line)
                continue
            }
            let rest = marked.dropFirst()
            lines.append(String(rest.first == " " ? rest.dropFirst() : rest))
        }
        flush()
        return runs
    }

    // Prompts can quote Markdown fences. Only a fence on its own line opens a block,
    // and a longer outer fence keeps any shorter fences inside it as literal code.
    static func segments(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var lines: [String] = []
        var fence: Fence?
        var language: String?

        func append(isCode: Bool, isOpen: Bool = false, trimProse: Bool = false) {
            let joined = lines.joined(separator: "\n")
            let body = trimProse && !isCode ? joined.trimmingCharacters(in: .newlines) : joined
            if isCode || !body.isEmpty {
                segments.append(MessageSegment(id: segments.count, text: body, isCode: isCode,
                                               language: language, isOpen: isOpen))
            }
            lines = []
        }

        for line in text.components(separatedBy: "\n") {
            let lineFence = Fence(line)
            if let opened = fence {
                if let lineFence, opened.isClosed(by: lineFence) {
                    append(isCode: true)
                    fence = nil
                    language = nil
                } else {
                    lines.append(line)
                }
            } else if let lineFence, lineFence.opens {
                append(isCode: false, trimProse: true)
                fence = lineFence
                language = lineFence.info.split(whereSeparator: \.isWhitespace).first.map(String.init)
            } else {
                lines.append(line)
            }
        }
        append(isCode: fence != nil, isOpen: fence != nil, trimProse: !segments.isEmpty)
        return segments
    }
}
