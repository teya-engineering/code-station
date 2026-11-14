import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var sentPromptCommandNames: Set<String> = []
}

// The conversation shares its command names so each bubble need not read the files.
struct SentPromptCommands: ViewModifier {
    let agent: AgentKind
    let workingDirectories: [String]
    let latestPromptID: UUID?
    @State private var names: Set<String> = []

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
                names = Set(commands.map { $0.name.lowercased() })
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
                        let prose = SelectableText(
                            prose: SentPrompt.inline(run.text,
                                                     commandNames: segment.id == 0 && offset == 0 ? commandNames : []),
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

    static func inline(_ text: String, commandNames: Set<String>) -> AttributedString {
        var attributed = AttributedString.inlineMarkdown(text)
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

        let command = text.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace })
        if command.hasPrefix("/"), commandNames.contains(String(command.dropFirst()).lowercased()),
           let range = attributed.range(of: String(command)),
           attributed[range].runs.allSatisfy({
               $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false)
           }) {
            attributed[range].foregroundColor = Theme.accent
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
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
