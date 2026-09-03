import AppKit
import SwiftUI

// One turn of the conversation. The user gets a bubble, Claude does not: long
// answers read better as plain page text than as a giant tinted block.
struct MessageView: View, Equatable {
    let message: ChatMessage
    let projectPath: String
    let textScale: CGFloat
    var openChange: (String) -> Void = { _ in }
    var openTerminal: () -> Void = {}
    var availableWidth: CGFloat?
    // The right-click menu on the user's own prompt. Its entries are built when the
    // menu opens, so what it offers reflects the session as it is then.
    var promptMenu: (() -> [MenuEntry])?

    // What the message is made of, and nothing else. The callbacks are left out on
    // purpose: each is a fresh closure on every redraw, so comparing them would say
    // every message had changed and the transcript would redraw whole while a turn
    // streams. Whether a prompt has a menu at all follows from the message, which is
    // compared.
    nonisolated static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.projectPath == b.projectPath
            && a.textScale == b.textScale && a.availableWidth == b.availableWidth
    }

    var body: some View {
        switch message.role {
        case .user:
            if let promptMenu {
                userBubble
                    .transcriptCopyButton(for: message.text)
                    .appContextMenu(promptMenu)
            } else {
                userBubble
                    .transcriptCopyButton(for: message.text)
            }
        case .assistant:
            assistantBody
        case .system:
            Text(message.text)
                .scaledMono(11)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
                    Text(message.text)
                        .scaledText(13.5)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: userBubbleContentWidth, alignment: .leading)
            .padding(.leading, 15)
            .padding(.trailing, message.text.isEmpty ? 15 : 42)
            .padding(.vertical, 11)
            // The corner nearest the writer is squared off, so the bubble points back at
            // the side of the page it came from.
            .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                               bottomTrailingRadius: 4, topTrailingRadius: 12)
                .fill(Theme.userMessage))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                            bottomTrailingRadius: 4, topTrailingRadius: 12)
                .stroke(Theme.userMessageRing))
            // The cap sits outside the background so it only limits how far long text
            // can wrap; the bubble itself hugs the text instead of filling the cap. It
            // grows with the text so a bubble holds about the same number of words at
            // every size.
            .frame(maxWidth: userBubbleWidth, alignment: .trailing)
        }
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
        let horizontalPadding: CGFloat = message.text.isEmpty ? 30 : 57
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
                                  openChange: openChange,
                                  openTerminal: openTerminal)
                        .transition(.fadeIn)
                case .prose(_, let text):
                    // The shared block keeps file previews and transcripts visually
                    // aligned. Chat adds its own copy affordance because the preview
                    // already supports text selection.
                    MarkdownProse(text: text, projectPath: projectPath, textScale: textScale) { segment in
                        MarkdownCodeBlock(segment: segment)
                            .transcriptCopyButton(for: segment.text, tooltip: "Copy code", inset: 6)
                    }
                    .padding(.trailing, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transcriptCopyButton(for: text.trimmed)
                case .thinking(_, let text):
                    ThinkingBlock(text: text)
                        .transition(.fadeIn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard let file = TranscriptLink.finderTarget(for: url) else { return .systemAction }
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSWorkspace.shared.selectFile(
                    nil,
                    inFileViewerRootedAtPath: file.deletingLastPathComponent().path)
            }
            return .handled
        })
    }
}

// The instructions carried alongside a prompt. They are the same on every turn of a
// session, so the bubble starts shut and only opens when someone wants to check them.
private struct InstructionBubble: View {
    let text: String
    @State private var expanded = false

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
                    Text(text)
                        .scaledText(13)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
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
    }
}

// A stretch of the model's reasoning. It is an aside, not part of the answer, so it
// folds down to one dim line and opens as dim italic text rather than as page prose.
private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

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
                Text(text.trimmed)
                    .scaledText(12)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                    .transcriptCopyButton(for: text)
                    .transition(.fadeIn)
            }
        }
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smoothlyResizes(when: expanded)
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
    let tooltip: String

    var body: some View {
        CopyButton(size: 11) { text }
            .frame(width: 24, height: 24)
            .cardSurface(cornerRadius: 6)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .appTooltip(tooltip)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var descendantHovering = false

    let text: String
    let tooltip: String
    let inset: CGFloat

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
                    CopyPill(text: text, tooltip: tooltip)
                        .padding(inset)
                        .transition(.fadeIn)
                }
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: descendantHovering)
            .accessibilityAction(named: tooltip) { Pasteboard.copy(text) }
            .transformPreference(DescendantCopyHoverKey.self) { $0 = $0 || hovering }
    }
}

private extension View {
    func transcriptCopyButton(for text: String,
                              tooltip: String = "Copy text",
                              inset: CGFloat = 4) -> some View {
        modifier(TranscriptCopyButton(text: text, tooltip: tooltip, inset: inset))
    }
}

// A run of prose or a fenced code block. Splitting on ``` is enough for what Claude
// Code emits and keeps the app free of a Markdown dependency.
struct MessageSegment: Identifiable {
    let id: Int
    let text: String
    let isCode: Bool
    var language: String?

    static func split(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            // Odd chunks sit between a pair of fences, so they are the code.
            let isCode = !index.isMultiple(of: 2)
            if !isCode {
                let prose = part.trimmed
                if !prose.isEmpty {
                    segments.append(MessageSegment(id: index, text: prose, isCode: false))
                }
                continue
            }

            var body = part
            var language: String?
            if let newline = part.firstIndex(of: "\n") {
                let firstLine = String(part[part.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
                // A fence opens either with a bare language tag or with nothing at all.
                if firstLine.isEmpty || !firstLine.contains(" ") {
                    language = firstLine.isEmpty ? nil : firstLine
                    body = String(part[part.index(after: newline)...])
                }
            }
            let code = body.trimmingCharacters(in: .newlines)
            if !code.isEmpty {
                segments.append(MessageSegment(id: index, text: code, isCode: true, language: language))
            }
        }
        return segments
    }
}
