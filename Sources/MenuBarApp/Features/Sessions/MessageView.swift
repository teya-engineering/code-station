import AppKit
import SwiftUI

// One turn of the conversation. The user gets a bubble, Claude does not: long
// answers read better as plain page text than as a giant tinted block.
struct MessageView: View, Equatable {
    let message: ChatMessage
    let projectPath: String
    let textScale: CGFloat
    var openChange: (String) -> Void = { _ in }
    var runInShell: (String) -> Void = { _ in }
    // Answers whether the link was taken into the app's explorer. Anything it turns down
    // goes to Finder.
    var showInExplorer: (URL) -> Bool = { _ in false }
    // Answers whether a link to a server on this machine was opened in the session's
    // preview. Anything it turns down goes to the browser.
    var openPreview: (URL) -> Bool = { _ in false }
    var availableWidth: CGFloat?
    // The right-click menu on the user's own prompt. Its entries are built when the
    // menu opens, so what it offers reflects the session as it is then.
    var promptMenu: (() -> [MenuEntry])?
    // Whether this is the prompt the composer has just sent, which lifts into place.
    var arriving = false
    var bubble = UserMessageStyle.leaf
    // Opens the second opinion ask dialog on this answer, from its hover actions. Nil where
    // the answer is not one to judge, such as one still being written.
    var secondOpinion: (@MainActor () -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showExternalNote) private var showExternalNote

    // What the message is made of, and nothing else. The callbacks are left out on
    // purpose: each is a fresh closure on every redraw, so comparing them would say
    // every message had changed and the transcript would redraw whole while a turn
    // streams. Whether a prompt has a menu at all follows from the message, which is
    // compared.
    nonisolated static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.projectPath == b.projectPath
            && a.textScale == b.textScale && a.availableWidth == b.availableWidth
            && a.arriving == b.arriving && a.bubble == b.bubble
            && (a.secondOpinion == nil) == (b.secondOpinion == nil)
    }

    var body: some View {
        content
            .environment(\.transcriptMessageID, message.id)
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user:
            if let promptMenu {
                userBubble
                    .transcriptCopyButton(for: message.text, inset: userBubbleCopyInset)
                    .appContextMenu(promptMenu)
            } else {
                userBubble
                    .transcriptCopyButton(for: message.text, inset: userBubbleCopyInset)
            }
        case .assistant:
            assistantBody
        case .system:
            SelectableText(plain: message.text,
                           size: 11,
                           design: .monospaced,
                           secondary: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transcriptCopyButton(for: message.text)
        case .instructions:
            InstructionBubble(text: message.text)
                .transcriptCopyButton(for: message.text)
        }
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: userBubbleLeadingSpace)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    if let paths = message.attachments, !paths.isEmpty {
                        // An image that is still on disk shows itself; anything else - other
                        // files, or an image gone since - keeps the chip and its name.
                        ForEach(paths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            if Attachment(url: url).isImage,
                               FileManager.default.fileExists(atPath: url.path) {
                                InlineImageView(url: url, maximumWidth: userBubbleContentWidth)
                            } else {
                                AttachmentChip(url: url)
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        SentPromptText(text: message.text)
                    }
                }
                if message.steered == true || message.dictated == true {
                    HStack(spacing: 10) {
                        if message.steered == true { SteeredTag() }
                        if message.dictated == true { DictatedTag() }
                    }
                }
            }
            .environment(\.colorScheme, bubble.inverts ? colorScheme.inverted : colorScheme)
            .padding(.leading, 15)
            .padding(.trailing, userBubbleTrailingPadding)
            .padding(.vertical, 11)
            // The corner nearest the writer is squared off, so the bubble points back at
            // the side of the page it came from.
            .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                               bottomTrailingRadius: 4, topTrailingRadius: 12)
                .fill(bubble.fill))
            // Clipped by the bubble, so the bar follows its rounded top corner and its
            // squared bottom one. A mask only hides pixels, so the bar would still take
            // every click on the bubble, links included, without turning hit testing off.
            .overlay(alignment: .trailing) {
                if let edge = bubble.edge {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                           bottomTrailingRadius: 4, topTrailingRadius: 12)
                        .fill(edge)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: Self.edgeWidth)
                        }
                        .allowsHitTesting(false)
                }
            }
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                            bottomTrailingRadius: 4, topTrailingRadius: 12)
                .stroke(bubble.ring))
            .modifier(PromptArrival(active: arriving,
                                    ringColour: bubble.inverts ? bubble.fill : bubble.ring,
                                    outline: UnevenRoundedRectangle(
                                        topLeadingRadius: 12, bottomLeadingRadius: 12,
                                        bottomTrailingRadius: 4, topTrailingRadius: 12)))
            // The cap sits outside the background so it only limits how far long text
            // can wrap; the bubble itself hugs the text instead of filling the cap. It
            // grows with the text so a bubble holds about the same number of words at
            // every size.
            .frame(maxWidth: userBubbleWidth, alignment: .trailing)
        }
        .environment(\.openURL, transcriptOpenURL)
    }

    private static let edgeWidth: CGFloat = 4

    // Says the prompt went into a turn already under way, so the reply above it reads as
    // written before the agent saw it.
    private struct SteeredTag: View {
        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("Steered into this turn")
                    .font(.mono(10.5, .medium))
            }
            .foregroundStyle(Theme.accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Steered into this turn")
        }
    }

    // Says the prompt was spoken, so a stray word in it reads as the engine's slip rather
    // than the writer's.
    private struct DictatedTag: View {
        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: "mic")
                    .font(.system(size: 10, weight: .medium))
                Text("Dictated")
                    .font(.mono(10.5, .medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictated")
        }
    }

    // The text and the copy button keep clear of the project's bar.
    private var userBubbleTrailingPadding: CGFloat {
        let edge = bubble.edge == nil ? 0 : Self.edgeWidth
        return (message.text.isEmpty ? 15 : 42) + edge
    }

    private var userBubbleCopyInset: CGFloat {
        bubble.edge == nil ? 4 : 4 + Self.edgeWidth
    }

    private var userBubbleLeadingSpace: CGFloat {
        availableWidth == nil ? 80 : 16
    }

    private var userBubbleWidth: CGFloat {
        let readableWidth = 600 * textScale
        guard let availableWidth else { return readableWidth }
        return min(readableWidth, max(0, availableWidth - userBubbleLeadingSpace))
    }

    private var userBubbleContentWidth: CGFloat {
        let horizontalPadding = 15 + userBubbleTrailingPadding
        return max(0, userBubbleWidth - horizontalPadding)
    }

    // The turn reads down the page in the order it happened, so a call the model made
    // after saying something sits under those words rather than above them.
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(message.blocks) { block in
                switch block {
                case .tools(_, let nodes):
                    ActivitySpine(nodes: nodes,
                                  projectPath: projectPath,
                                  messageID: message.id,
                                  openChange: openChange,
                                  runInShell: runInShell)
                        .transition(.fadeIn)
                case .prose(_, let text):
                    // The shared block keeps file previews and transcripts visually
                    // aligned. Chat adds its own copy affordance because the preview
                    // already supports text selection.
                    MarkdownProse(text: text, projectPath: projectPath, textScale: textScale) { segment in
                        MarkdownCodeBlock(segment: segment)
                            .equatable()
                            .transcriptCopyButton(for: segment.text, tooltip: "Copy code", inset: 6)
                    }
                    .padding(.trailing, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transcriptCopyButton(for: text.trimmed, secondOpinion: secondOpinion)
                case .thinking(_, let text):
                    ThinkingBlock(text: text)
                        .transition(.fadeIn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, transcriptOpenURL)
    }

    private var transcriptOpenURL: OpenURLAction {
        let note = showExternalNote.show
        return OpenURLAction { url in
            if TranscriptLink.isLocalServer(url), openPreview(url) { return .handled }
            guard let file = TranscriptLink.finderTarget(for: url) else {
                let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                note?(web ? "Opened the link in your browser" : "Opened the link", "arrow.up.forward.app")
                return .systemAction
            }
            if showInExplorer(url) { return .handled }
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
                note?("Revealed \(file.lastPathComponent) in Finder", "folder")
            } else {
                NSWorkspace.shared.selectFile(
                    nil,
                    inFileViewerRootedAtPath: file.deletingLastPathComponent().path)
                note?("Opened the folder in Finder", "folder")
            }
            return .handled
        }
    }
}

// The instructions carried alongside a prompt. They are the same on every turn of a
// session, so the bubble starts shut and only opens when someone wants to check them.
private struct InstructionBubble: View {
    let text: String
    @State private var expanded = false
    @Environment(\.transcriptFind) private var find
    @Environment(\.transcriptMessageID) private var messageID

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 6) {
                DisclosureHeader(isExpanded: $expanded,
                                 show: "Show instructions", hide: "Hide instructions") {
                    Text(expanded ? "Instructions" : "Instructions\u{2026} click to expand")
                        .scaledText(13)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if expanded {
                    SelectableText(plain: text, size: 13)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 18)
                        .transition(.fadeIn)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 42)
            .padding(.vertical, 10)
            .surface(Theme.secret.opacity(0.14), cornerRadius: 12,
                     border: Theme.secret.opacity(0.30))
        }
        .smoothlyResizes(when: expanded)
        .onChange(of: find?.reveals(text, in: messageID) == true, initial: true) { _, reveals in
            if reveals { expanded = true }
        }
    }
}

// A stretch of the model's reasoning. It is an aside, not part of the answer, so it
// folds down to one dim line and opens as dim italic text rather than as page prose.
private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false
    @Environment(\.transcriptFind) private var find
    @Environment(\.transcriptMessageID) private var messageID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureHeader(isExpanded: $expanded, show: "Show thinking", hide: "Hide thinking") {
                Text(expanded ? "Thought" : "Thought · \(firstLine)")
                    .scaledText(12)
                    .italic()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.secondary)

            if expanded {
                SelectableText(plain: text.trimmed,
                               size: 12,
                               secondary: true,
                               italic: true,
                               lineSpacing: 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    .transcriptCopyButton(for: text)
                    .transition(.fadeIn)
            }
        }
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smoothlyResizes(when: expanded)
        .onChange(of: find?.reveals(text, in: messageID) == true, initial: true) { _, reveals in
            if reveals { expanded = true }
        }
    }

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

// The transcript's copy affordance, shared by whole messages and by single code blocks:
// the copy button on a small card lifted off the page, since it floats over text rather
// than sitting in a row of its own.
private struct CopyPill: View {
    let text: String
    let tooltip: Tooltip

    var body: some View {
        CopyButton(size: TranscriptCopyButton.iconSize) { text }
            .frame(width: TranscriptCopyButton.pillSize, height: TranscriptCopyButton.pillSize)
            .cardSurface(cornerRadius: 7)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .appTooltip { tooltip }
    }
}

// Copy buttons nest: a message's pill wraps prose that can hold code blocks with pills
// of their own. Hovering a code block also counts as hovering the message, so without
// coordination two identical pills would sit side by side. Each button reports its hover
// up through this key and any enclosing button stands down, leaving the one pill whose
// reach matches what the pointer is over.
private struct DescendantCopyHoverKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct TranscriptCopyButton: ViewModifier {
    @State private var hovering = false
    @State private var descendantHovering = false

    let text: String
    let tooltip: String
    let inset: CGFloat
    var secondOpinion: (@MainActor () -> Void)?

    static let pillSize: CGFloat = 28
    static let iconSize: CGFloat = 13

    private var copyTooltip: Tooltip {
        Tooltip(title: tooltip,
                subtitle: tooltip == "Copy code" ? "Puts this code block on the clipboard"
                    : "Puts this message on the clipboard")
    }

    func body(content: Content) -> some View {
        content
            // The pill can sit beyond the rendered text in a full-width frame. Keep the
            // transparent space on the path to it inside the owner's hover area.
            .contentShape(Rectangle())
            // Read before our own flag is merged in below, so this sees descendants
            // only and a pill never hides itself.
            .onPreferenceChange(DescendantCopyHoverKey.self) { descendantHovering = $0 }
            .overlay(alignment: .topTrailing) {
                if hovering && !descendantHovering && !text.isEmpty {
                    Group {
                        if let secondOpinion {
                            // Asking and copying share one card, the reviewers first.
                            HStack(spacing: 0) {
                                AnswerLineupButton(action: secondOpinion)
                                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16)
                                CopyButton(size: Self.iconSize) { text }
                                    .frame(width: Self.pillSize, height: Self.pillSize)
                                    .appTooltip { copyTooltip }
                            }
                            .cardSurface(cornerRadius: 7)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        } else {
                            CopyPill(text: text, tooltip: copyTooltip)
                        }
                    }
                    .padding(inset)
                    .transition(.fadeIn)
                }
            }
            .onPointerHover { hovering = $0 }
            .motion(Motion.hover, value: hovering)
            .motion(Motion.hover, value: descendantHovering)
            .accessibilityAction(named: tooltip) { Pasteboard.copy(text) }
            .accessibilityActions {
                if let secondOpinion { Button("Get a second opinion", action: secondOpinion) }
            }
            .transformPreference(DescendantCopyHoverKey.self) { $0 = $0 || hovering }
    }
}

extension View {
    func transcriptCopyButton(for text: String,
                              tooltip: String = "Copy text",
                              inset: CGFloat = 4,
                              secondOpinion: (@MainActor () -> Void)? = nil) -> some View {
        modifier(TranscriptCopyButton(text: text, tooltip: tooltip, inset: inset, secondOpinion: secondOpinion))
    }
}

// A run of prose or a fenced block. Fences are read line by line, the way Markdown reads
// them, which keeps the app free of a Markdown dependency. A fence is also how a reply asks
// for something the app draws itself, such as a chart: an agent writes fenced blocks
// reliably and a tag it invented still reads as code, so nothing is lost when a block is
// not one the app knows.
struct MessageSegment: Identifiable, Equatable {
    let id: Int
    let text: String
    let isCode: Bool
    var language: String?
    // A block whose closing fence has not arrived yet. A reply is drawn as it streams, so
    // the last block of one still running is usually half of what it will be.
    var isOpen = false

    var isChart: Bool { isCode && language == TranscriptChartSpec.fenceLanguage }
    var isTrace: Bool { isCode && language == TranscriptTraceSpec.fenceLanguage }
    var isLogs: Bool { isCode && language == TranscriptLogsSpec.fenceLanguage }
    // A block the app draws rather than prints.
    var isDrawn: Bool { isChart || isTrace || isLogs }

    static func split(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var lines: [String] = []
        // Counts the fences seen so far, so a segment keeps its id as more of a streaming
        // reply arrives after it.
        var fences = 0
        var opened: (fence: Fence, depth: Int, language: String?)?

        for line in text.components(separatedBy: "\n") {
            if let block = opened {
                let body = block.depth > 0 ? unquoted(line, depth: block.depth) : line
                if let fence = Fence(body), block.fence.isClosed(by: fence) {
                    let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    // An empty suggestion is how a GitHub review comment asks to delete the lines.
                    if !code.isEmpty || block.language == suggestionLanguage {
                        segments.append(MessageSegment(id: fences, text: code, isCode: true,
                                                       language: block.language))
                    }
                    lines = []
                    fences += 1
                    opened = nil
                } else {
                    lines.append(body)
                }
                continue
            }

            let (depth, rest) = quoted(line)
            guard let fence = Fence(rest), fence.opens else {
                lines.append(line)
                continue
            }
            // The quote markers a fence opens on would draw as empty quote lines.
            if depth > 0 {
                while let last = lines.last, String(quoted(last).rest).trimmed.isEmpty {
                    lines.removeLast()
                }
            }
            let prose = lines.joined(separator: "\n").trimmed
            if !prose.isEmpty {
                segments.append(MessageSegment(id: fences, text: prose, isCode: false))
            }
            lines = []
            fences += 1
            opened = (fence, depth, fence.info.split(whereSeparator: \.isWhitespace).first.map(String.init))
        }

        if let block = opened {
            let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !code.isEmpty {
                segments.append(MessageSegment(id: fences, text: code, isCode: true,
                                               language: block.language, isOpen: true))
            }
        } else {
            let prose = lines.joined(separator: "\n").trimmed
            if !prose.isEmpty {
                segments.append(MessageSegment(id: fences, text: prose, isCode: false))
            }
        }
        return segments
    }

    static let suggestionLanguage = "suggestion"

    var isDeletion: Bool { isCode && language == Self.suggestionLanguage && text.isEmpty }

    // How many quote markers the line starts with, and what follows them.
    private static func quoted(_ line: String) -> (depth: Int, rest: Substring) {
        var rest = Substring(line)
        var depth = 0
        while case let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" }), trimmed.first == ">" {
            rest = trimmed.dropFirst()
            depth += 1
        }
        return (depth, depth > 0 && rest.first == " " ? rest.dropFirst() : rest)
    }

    private static func unquoted(_ line: String, depth: Int) -> String {
        var rest = Substring(line)
        for _ in 0..<depth {
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.first == ">" else { break }
            rest = trimmed.dropFirst()
        }
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }
}

// A line of three or more backticks or tildes. A block only closes on a fence of the same
// character that is at least as long, so a longer outer fence holds shorter ones as code.
struct Fence {
    let marker: String
    let info: String

    init?(_ line: some StringProtocol) {
        let indent = line.prefix(while: { $0 == " " })
        let content = line.dropFirst(indent.count)
        let marker = content.prefix(while: { $0 == content.first })
        guard indent.count <= 3, marker.count >= 3, marker.first == "`" || marker.first == "~" else {
            return nil
        }
        self.marker = String(marker)
        info = content.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Without this, inline code written as ```code``` at the start of a line would open a block.
    var opens: Bool { marker.first == "~" || !info.contains("`") }

    func isClosed(by fence: Fence) -> Bool {
        fence.marker.first == marker.first && fence.marker.count >= marker.count && fence.info.isEmpty
    }
}

private extension ColorScheme {
    var inverted: ColorScheme { self == .dark ? .light : .dark }
}
