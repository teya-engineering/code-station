import Foundation

// What an open session sends its reader after the first snapshot: a fresh snapshot when
// the reader asked to resync, and otherwise only what moved. Each event carries its own
// `type`, the phone's word for it, so the stream can cross a socket unchanged.
public enum StationSessionEvent: Codable, Equatable, Sendable {
    case snapshot(RemoteSnapshot)
    case update(RemoteUpdate)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try RemoteSnapshot(from: decoder))
        case "update": self = .update(try RemoteUpdate(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown event \(type)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .snapshot(let snapshot): try snapshot.encode(to: encoder)
        case .update(let update): try update.encode(to: encoder)
        }
    }
}

// A session opened through the façade: how it stands now, then every change after.
// The stream ends when the session is closed or goes away.
public struct OpenedSession: Sendable {
    public let snapshot: RemoteSnapshot
    public let events: AsyncStream<StationSessionEvent>

    public init(snapshot: RemoteSnapshot, events: AsyncStream<StationSessionEvent>) {
        self.snapshot = snapshot
        self.events = events
    }
}

// A reader's copy of an open session, kept up to date by laying each event over it the
// way the phone's page does. A patch that does not fit what the reader holds means the
// two have drifted apart, and only a resync can say what the truth is.
public struct RemoteTranscript: Equatable, Sendable {
    public private(set) var header: RemoteHeader
    public private(set) var messages: [RemoteMessage]
    public private(set) var queued: [RemoteQueuedPrompt]
    public private(set) var permission: RemotePermission?

    public init(_ snapshot: RemoteSnapshot) {
        header = snapshot.header
        messages = snapshot.messages
        queued = snapshot.queued
        permission = snapshot.permission
    }

    // False when the event did not fit and the reader should ask for a resync.
    @discardableResult
    public mutating func apply(_ event: StationSessionEvent) -> Bool {
        switch event {
        case .snapshot(let snapshot):
            self = RemoteTranscript(snapshot)
            return true
        case .update(let update):
            return apply(update)
        }
    }

    @discardableResult
    public mutating func apply(_ update: RemoteUpdate) -> Bool {
        if let header = update.header { self.header = header }
        if let queued = update.queued { self.queued = queued }
        if update.permissionCleared == true { permission = nil }
        if let permission = update.permission { self.permission = permission }

        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fits = true
        for change in update.changed ?? [] {
            if change.kind == "full" {
                byID[change.id] = RemoteMessage(id: change.id, role: change.role ?? "",
                                                text: change.text ?? "",
                                                date: change.date ?? Date(),
                                                attachments: change.attachments ?? [],
                                                blocks: change.blocks ?? [])
                continue
            }
            guard var message = byID[change.id], Self.patch(&message, with: change) else {
                fits = false
                continue
            }
            byID[change.id] = message
        }
        let order = update.order ?? messages.map(\.id)
        messages = order.compactMap { byID[$0] }
        return fits && messages.count == order.count
    }

    // Text goes on the end of the message and of its last prose block; a tool takes the
    // place of the one with its id.
    private static func patch(_ message: inout RemoteMessage, with change: RemoteChange) -> Bool {
        if let append = change.textAppend {
            guard let last = message.blocks.lastIndex(where: { $0.kind == "prose" }) else { return false }
            message.text += append
            message.blocks[last].text = (message.blocks[last].text ?? "") + append
        }
        for tool in change.tools ?? [] {
            guard let block = message.blocks.firstIndex(where: {
                $0.tools?.contains { $0.id == tool.id } == true
            }), let at = message.blocks[block].tools?.firstIndex(where: { $0.id == tool.id }) else {
                return false
            }
            message.blocks[block].tools?[at] = tool
        }
        return true
    }
}
