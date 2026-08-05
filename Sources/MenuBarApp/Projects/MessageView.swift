import SwiftUI

// Colours the chat shares with the rest of the app. They live here rather than in
// Theme because Theme is a shared file the chat views only read from.
enum ChatColor {
    static let warningText = Color(red: 0.55, green: 0.20, blue: 0.16)
    static let warningBackground = Color(red: 0.98, green: 0.90, blue: 0.88)
}

// One turn of the conversation. The user gets a bubble, Claude does not: long
// answers read better as plain page text than as a giant tinted block.
struct MessageView: View {
    let message: ChatMessage
    let projectPath: String
    let openChanges: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBody
        case .system:
            Text(message.text)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.22)))
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tools run before Claude writes about what it did, so they read first.
            if !message.tools.isEmpty {
                ActivitySpine(tools: message.tools,
                              projectPath: projectPath,
                              openChanges: openChanges)
            }

            ForEach(MessageSegment.split(message.text)) { segment in
                if segment.isCode {
                    CodeBlock(segment: segment)
                } else {
                    Text(inline(segment.text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Inline markdown only: `code`, bold and italics render, newlines stay as they
    // are. Fenced blocks are already split out before this runs.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
