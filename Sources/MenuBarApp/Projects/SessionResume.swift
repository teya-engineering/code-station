import Foundation
import SwiftUI

// Where a person had read to before leaving a session. A turn is one assistant message
// that keeps changing while it runs, so the message id alone is not a boundary: the text
// can grow, new calls can start, and a call already on screen can finish while the session
// is away. The small cursor records each of those edges without copying transcript data
// into the project index.
struct SessionResumeBoundary: Codable, Equatable, Sendable {
    let messageID: UUID?
    let textLength: Int
    let toolCount: Int
    let pendingToolIDs: [String]
    let seenAt: Date

    init(messages: [ChatMessage], seenAt: Date = Date()) {
        let message = messages.last
        messageID = message?.id
        textLength = message?.text.count ?? 0
        toolCount = message?.tools.count ?? 0
        pendingToolIDs = message?.tools.filter(\.isRunning).map(\.id) ?? []
        self.seenAt = seenAt
    }
}

// The trustworthy, compact reading of what happened after a boundary. It deliberately
// keeps the agent's own words and measurements from tool events rather than generating a
// second account of the work that could disagree with the transcript.
struct SessionResumeBrief: Equatable, Sendable {
    let seenAt: Date
    let lastRequest: String?
    let agentReport: String?
    let completedCalls: Int
    let failedCalls: Int
    let runningCalls: Int
    let changedFiles: Int
    let added: Int
    let removed: Int

    var hasChanges: Bool { changedFiles > 0 || added > 0 || removed > 0 }

    static func make(messages: [ChatMessage], boundary: SessionResumeBoundary,
                     projectPath: String) -> SessionResumeBrief? {
        guard let delta = Delta(messages: messages, boundary: boundary) else { return nil }

        let completed = delta.tools.filter { !$0.isRunning }
        let successful = completed.filter { !$0.isError }
        let presentations = successful.map {
            ToolPresentationCache.presentation(for: $0, projectPath: projectPath)
        }

        var fileNames: Set<String> = []
        var unnamedFiles = 0
        var added = 0
        var removed = 0
        for presentation in presentations {
            let names = Set(presentation.changes.map(\.name))
            fileNames.formUnion(names)
            unnamedFiles += max(0, presentation.changedFiles - names.count)
            added += presentation.added ?? 0
            removed += presentation.removed ?? 0
        }

        let report = delta.assistantTexts.reversed().compactMap(reportLine).first
        let request = messages.reversed().first(where: { $0.role == .user })
            .flatMap { conciseLine($0.text) }
        let failed = completed.count(where: \.isError)
        let running = delta.tools.count(where: \.isRunning)

        guard report != nil || (request != nil && delta.hasNewUserText)
                || !delta.tools.isEmpty else { return nil }
        return SessionResumeBrief(
            seenAt: boundary.seenAt,
            lastRequest: request,
            agentReport: report,
            completedCalls: completed.count,
            failedCalls: failed,
            runningCalls: running,
            changedFiles: fileNames.count + unnamedFiles,
            added: added,
            removed: removed)
    }

    private static func conciseLine(_ text: String) -> String? {
        guard let raw = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let withoutMarkdown = raw.drop(while: { "#-*>•".contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let words = withoutMarkdown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > 180 ? String(words.prefix(180)) + "…" : words
    }

    // Text blocks in one turn are separated by a blank line. The last block is the
    // agent's latest report, while the first can be an intent written before any work.
    private static func reportLine(_ text: String) -> String? {
        text.components(separatedBy: "\n\n").reversed().compactMap(conciseLine).first
    }

    private struct Delta {
        var tools: [ToolUse] = []
        var assistantTexts: [String] = []
        var hasNewUserText = false

        init?(messages: [ChatMessage], boundary: SessionResumeBoundary) {
            let firstIndex: Int
            if let messageID = boundary.messageID {
                guard let found = messages.firstIndex(where: { $0.id == messageID }) else {
                    return nil
                }
                firstIndex = found
                let message = messages[found]
                if message.text.count > boundary.textLength {
                    let seenEnd = message.text.index(
                        message.text.startIndex, offsetBy: boundary.textLength)
                    addText(String(message.text[seenEnd...]), role: message.role)
                }

                let knownCount = min(boundary.toolCount, message.tools.count)
                let pending = Set(boundary.pendingToolIDs)
                tools.append(contentsOf: message.tools[..<knownCount].filter {
                    pending.contains($0.id) && !$0.isRunning
                })
                tools.append(contentsOf: message.tools.dropFirst(knownCount))
            } else {
                firstIndex = -1
            }

            for message in messages.dropFirst(firstIndex + 1) {
                addText(from: message)
                tools.append(contentsOf: message.tools)
            }
        }

        private mutating func addText(from message: ChatMessage) {
            addText(message.text, role: message.role)
        }

        private mutating func addText(_ text: String, role: MessageRole) {
            switch role {
            case .assistant:
                if !text.isBlank { assistantTexts.append(text) }
            case .user:
                hasNewUserText = hasNewUserText || !text.isBlank
            case .system, .instructions:
                break
            }
        }
    }
}

// A return cue that stays above the work until the person either follows its next action
// or puts it away. The transcript remains the full record; this card is only the index
// back into it.
struct SessionResumeBriefView: View {
    let brief: SessionResumeBrief
    let openChanges: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.attentionText)
                Text("SINCE YOUR LAST VISIT")
                    .font(.mono(10, .semibold))
                    .kerning(1.1)
                    .foregroundStyle(Theme.attentionText)
                StatusDot()
                Text(brief.seenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                GlyphButton(icon: "xmark", side: 25, action: dismiss)
                    .appTooltip("Dismiss return brief")
                    .accessibilityLabel("Dismiss return brief")
            }

            if let request = brief.lastRequest {
                resumeLine(label: "LAST REQUEST", text: request, weight: .semibold)
            }
            if let report = brief.agentReport {
                resumeLine(label: "AGENT REPORTED", text: report)
            }

            HStack(spacing: 8) {
                if brief.changedFiles > 0 {
                    MonoChip(text: counted(brief.changedFiles, "FILE").uppercased(),
                             tint: Theme.accent)
                }
                if brief.added > 0 || brief.removed > 0 {
                    DiffPair(added: brief.added, removed: brief.removed, size: 10.5)
                }
                if brief.completedCalls > 0 {
                    MonoChip(text: counted(brief.completedCalls, "ACTION").uppercased())
                }
                if brief.failedCalls > 0 {
                    MonoChip(text: counted(brief.failedCalls, "FAILED ACTION").uppercased(),
                             tint: Theme.deletion)
                }
                if brief.runningCalls > 0 {
                    MonoChip(text: "\(brief.runningCalls) STILL RUNNING",
                             tint: Theme.addition)
                }

                Spacer(minLength: 12)

                if brief.hasChanges {
                    ActionButton(title: "Review changes", tone: .attention,
                                 height: 28, size: 11.5, action: openChanges)
                } else {
                    ActionButton(title: brief.failedCalls > 0 ? "Inspect failure" : "Review result",
                                 tone: .outlined, height: 28, size: 11.5, action: dismiss)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .surface(Theme.attention.opacity(0.08), cornerRadius: 11,
                 border: Theme.attention.opacity(0.38))
    }

    private func resumeLine(label: String, text: String,
                            weight: Font.Weight = .regular) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(0.7)
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .leading)
            Text(text)
                .font(.system(size: 12.5, weight: weight))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
