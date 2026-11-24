import Foundation

struct RemoteMessageDigest: Equatable {
    let role: String
    let date: Date
    let textCount: Int
    let textHash: Int
    let structure: Int
    let attachments: Int
    let toolOrder: [String]
    let tools: [String: Int]
}

enum RemoteTranscriptDiff {
    static func digest(of message: RemoteMessage) -> RemoteMessageDigest {
        RemoteMessageDigest(
            role: message.role,
            date: message.date,
            textCount: message.text.count,
            textHash: message.text.hashValue,
            structure: message.structureDigest,
            attachments: message.attachments.hashValue,
            toolOrder: message.tools.map(\.id),
            tools: Dictionary(message.tools.map { ($0.id, $0.digest) },
                              uniquingKeysWith: { first, _ in first }))
    }

    // A live answer grows one chunk at a time, so the usual change is a longer text with
    // everything else untouched. Anything that rewrites what the phone already drew falls
    // back to the whole message, since patching it would need the old text to undo.
    static func change(from previous: RemoteMessageDigest, to current: RemoteMessageDigest,
                       message: RemoteMessage) -> RemoteChange {
        guard previous.role == current.role,
              previous.date == current.date,
              previous.structure == current.structure,
              previous.attachments == current.attachments,
              previous.toolOrder == current.toolOrder,
              current.textCount >= previous.textCount else { return .full(message) }

        var appended: String?
        if previous.textHash != current.textHash {
            let kept = String(message.text.prefix(previous.textCount))
            guard kept.hashValue == previous.textHash else { return .full(message) }
            appended = String(message.text.dropFirst(previous.textCount))
        }

        let tools = message.tools.filter { previous.tools[$0.id] != current.tools[$0.id] }
        return .patch(id: message.id, textAppend: appended, tools: tools.isEmpty ? nil : tools)
    }
}
