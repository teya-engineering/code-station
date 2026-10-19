import CodeStationCore

// What a reader takes off the transcript to the clipboard: a message as it was written,
// or one fenced code block of it, found through the line source under a line.
public enum TranscriptCopy {

    // A prompt or a note as typed. A reply as the markdown of its prose, without its
    // thinking or its tool calls, which are not what anyone pastes elsewhere.
    public static func text(of message: RemoteMessage) -> String {
        guard message.role == "assistant" else { return message.text }
        let prose = message.blocks.filter { $0.kind == "prose" }.compactMap(\.text).filter { !$0.isEmpty }
        return prose.isEmpty ? message.text : prose.joined(separator: "\n\n")
    }

    // The code of the fenced block a line belongs to, as written: tabs and all, without
    // its fences. Nil when the line is not in a code block of this message.
    public static func code(in message: RemoteMessage, at source: LineSource) -> String? {
        guard let index = source.code, source.messageID == message.id, message.role == "assistant" else {
            return nil
        }
        // A reply with no blocks is drawn as one prose block of its text.
        let prose: String?
        if message.blocks.isEmpty {
            prose = message.text
        } else if let block = source.block, message.blocks.indices.contains(block) {
            prose = message.blocks[block].text
        } else {
            prose = nil
        }
        let code = TerminalMarkdown.blocks(prose ?? "").compactMap { block -> String? in
            if case .code(_, let text) = block { return text }
            return nil
        }
        return code.indices.contains(index) ? code[index] : nil
    }
}
