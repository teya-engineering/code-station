import SwiftUI

// Colours the chat shares with the rest of the app. They live here rather than in
// Theme because Theme is a shared file the chat views only read from.
enum ChatColor {
    static let error = Color(red: 0.75, green: 0.28, blue: 0.24)
    static let warningText = Color(red: 0.55, green: 0.20, blue: 0.16)
    static let warningBackground = Color(red: 0.98, green: 0.90, blue: 0.88)
}

// One turn of the conversation. The user gets a bubble, Claude does not: long
// answers read better as plain page text than as a giant tinted block.
struct MessageView: View {
    let message: ChatMessage

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
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.22)))
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tools run before Claude writes about what it did, so they read first.
            ForEach(message.tools) { ToolRow(tool: $0) }

            ForEach(MessageSegment.split(message.text)) { segment in
                if segment.isCode {
                    CodeBlock(segment: segment)
                } else {
                    Text(segment.text)
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

// One tool call: a single line until you click it, because a turn can contain a
// dozen of them and the detail is rarely what you are reading for.
struct ToolRow: View {
    let tool: ToolUse
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Chip(text: tool.name)
                    Text(singleLine(tool.input))
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if tool.isRunning {
                        ProgressView().controlSize(.small)
                    } else if tool.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ChatColor.error)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !tool.input.isEmpty {
                    detailBox(text: tool.input, tinted: false)
                }
                if let result = tool.result, !result.isEmpty {
                    detailBox(text: result, tinted: tool.isError)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .animation(.easeInOut(duration: 0.12), value: expanded)
    }

    private func detailBox(text: String, tinted: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.mono(11))
                .foregroundStyle(tinted ? ChatColor.error : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        // Tool output can be a whole file, so cap it and let the box scroll.
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(tinted ? ChatColor.warningBackground : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}
