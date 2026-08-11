import AppKit
import SwiftUI

// Colours the chat shares with the rest of the app. They live here rather than in
// Theme because Theme is a shared file the chat views only read from.
// Both halves are adaptive: a surface that stayed pink in dark mode would be left holding
// the white that .primary and .secondary turn into.
enum ChatColor {
    static let warningText = Theme.adaptive(
        light: NSColor(srgbRed: 0.55, green: 0.20, blue: 0.16, alpha: 1),
        dark: NSColor(srgbRed: 0.95, green: 0.64, blue: 0.56, alpha: 1))
    static let warningBackground = Theme.adaptive(
        light: NSColor(srgbRed: 0.98, green: 0.90, blue: 0.88, alpha: 1),
        dark: NSColor(srgbRed: 0.22, green: 0.11, blue: 0.10, alpha: 1))
}

// How anything new lands in the transcript: it fades in where it appears. Arrival is
// one-way, so nothing fades out - a row that leaves mid-stream would ghost under the
// row replacing it.
extension AnyTransition {
    static var fadeIn: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }
}

// One turn of the conversation. The user gets a bubble, Claude does not: long
// answers read better as plain page text than as a giant tinted block.
struct MessageView: View, Equatable {
    let message: ChatMessage
    let projectPath: String
    let isTurnActive: Bool
    let openChanges: () -> Void

    // What the message is made of, and nothing else. The callback is left out on purpose:
    // it is a fresh closure on every redraw, so comparing it would say every message had
    // changed and the transcript would redraw whole while a turn streams.
    nonisolated static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.projectPath == b.projectPath
            && a.isTurnActive == b.isTurnActive
    }

    var body: some View {
        switch message.role {
        case .user:
            userBubble
                .transcriptCopyButton(for: message.text)
        case .assistant:
            assistantBody
        case .system:
            Text(message.text)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transcriptCopyButton(for: message.text)
        case .instructions:
            instructionBubble
                .transcriptCopyButton(for: message.text)
        }
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 8) {
                if let paths = message.attachments, !paths.isEmpty {
                    ForEach(paths, id: \.self) { path in
                        AttachmentChip(url: URL(fileURLWithPath: path))
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
            // can wrap; the bubble itself hugs the text instead of filling the cap.
            .frame(maxWidth: 600, alignment: .trailing)
        }
    }

    private var instructionBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14)
                .padding(.trailing, 42)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.secret.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.secret.opacity(0.30)))
        }
    }

    // The turn reads down the page in the order it happened, so a call the model made
    // after saying something sits under those words rather than above them.
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(message.blocks) { block in
                switch block {
                case .tools(_, let nodes):
                    ActivitySpine(nodes: nodes,
                                  projectPath: projectPath,
                                  openChanges: openChanges,
                                  isTurnActive: isTurnActive)
                        .transition(.fadeIn)
                case .prose(_, let text):
                    VStack(alignment: .leading, spacing: 12) {
                        prose(text)
                    }
                    .padding(.trailing, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transcriptCopyButton(
                        for: text.trimmingCharacters(in: .whitespacesAndNewlines))
                case .thinking(_, let text):
                    ThinkingBlock(text: text)
                        .transition(.fadeIn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func prose(_ text: String) -> some View {
        ForEach(MessageSegment.split(text)) { segment in
            if segment.isCode {
                CodeBlock(segment: segment)
                    .transition(.fadeIn)
            } else {
                ForEach(MarkdownBlock.parse(segment.text)) { block in
                    MarkdownBlockView(block: block)
                        .equatable()
                        .transition(.fadeIn)
                }
            }
        }
    }
}

// A stretch of the model's reasoning. It is an aside, not part of the answer, so it
// folds down to one dim line and opens as dim italic text rather than as page prose.
private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Text(expanded ? "Thought" : "Thought · \(firstLine)")
                        .font(.system(size: 12))
                        .italic()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip(expanded ? "Hide thinking" : "Show thinking")

            if expanded {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                    .transcriptCopyButton(for: text)
            }
        }
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.12), value: expanded)
    }

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

private struct TranscriptCopyButton: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false

    let text: String

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering && !text.isEmpty {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(copied ? Theme.addition : Theme.accent)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .appTooltip(copied ? "Copied" : "Copy text")
                    .transition(.opacity)
                }
            }
            .onHover { inside in
                hovering = inside
                if !inside { copied = false }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .accessibilityAction(named: "Copy text", copy)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

private extension View {
    func transcriptCopyButton(for text: String) -> some View {
        modifier(TranscriptCopyButton(text: text))
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
                let prose = part.trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct CodeBlock: View {
    let segment: MessageSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language = segment.language {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            // Code lines are long; scrolling sideways beats wrapping them.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(segment.text)
                    .font(.mono(12))
                    .textSelection(.enabled)
                    .padding(.trailing, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}
