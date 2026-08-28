import Foundation

// The wire format between the Mac and a paired browser: what the phone is sent, and the
// commands it sends back. A change to any type here is a change the phone has to
// understand, which is why they are kept apart from the controller that fills them in.

// What the phone asks for. The type names the command and says which of the other
// fields matter; a command the Mac does not know fails to decode rather than being
// guessed at.
struct RemoteCommand: Decodable, Equatable {
    enum Kind: String, Decodable {
        case authenticate, openSession, closeSession, createSession, resync
        case sendPrompt, stopTurn, answerPermission
    }

    enum Answer: String, Decodable {
        case allowOnce, allowAlways, deny, answers
    }

    let type: Kind
    var version: Int?
    var secret: String?
    var prompt: String?
    var requestID: String?
    var answer: Answer?
    var answers: [String: String]?
    var sessionID: String?
    var projectID: String?
    var worktree: Bool?
}

// The list a browsing code opens on. It is compared with the last one sent before it goes
// out, so a phone sitting on the list costs nothing until something in it moves.
struct RemoteDirectory: Encodable, Equatable {
    let type = "directory"
    let version = 1
    let title: String
    let canCreate: Bool
    let projects: [RemoteProject]
}

struct RemoteProject: Encodable, Equatable {
    let id: String
    let name: String
    let path: String
    // Whether a session here can have a checkout of its own, which is the one choice the
    // phone offers when starting one.
    let isGit: Bool
    let isMissing: Bool
    let sessions: [RemoteSessionRow]
}

struct RemoteSessionRow: Encodable, Equatable {
    let id: String
    let title: String
    let agent: String
    let workspace: String?
    let branch: String?
    let state: String
    let lastActivity: Date
    let added: Int
    let removed: Int
}

struct RemoteHeader: Encodable, Equatable {
    let title: String
    let project: String
    let agent: String
    let branch: String?
    let state: String
    // What the elapsed time on the strip counts from: the start of the turn while one is
    // running, and the last thing that happened otherwise.
    let since: Date
    let failure: String?
    let isBusy: Bool
    let added: Int
    let removed: Int
    let context: Double?
    let queuedPrompts: Int
    let hasEarlierMessages: Bool
}

struct RemoteSnapshot: Encodable {
    let type = "snapshot"
    let version = 1
    let sessionID: String
    // Whether there is a list to go back to, which is what puts the back arrow on the
    // header of a session opened from a project or from the whole app.
    let canBrowse: Bool
    let header: RemoteHeader
    let messages: [RemoteMessage]
    let queued: [RemoteQueuedPrompt]
    let permission: RemotePermission?
}

// Only the parts that moved. An absent field means the phone should keep what it has, which
// is why a cleared permission needs a flag of its own rather than a missing one.
struct RemoteUpdate: Encodable {
    let type = "update"
    let version = 1
    var header: RemoteHeader?
    var order: [String]?
    var changed: [RemoteChange]?
    var queued: [RemoteQueuedPrompt]?
    var permission: RemotePermission?
    var permissionCleared: Bool?

    var isEmpty: Bool {
        header == nil && order == nil && changed == nil && queued == nil
            && permission == nil && permissionCleared == nil
    }
}

struct RemoteQueuedPrompt: Encodable, Equatable {
    let id: String
    let text: String
    let attachments: [String]

    init(_ prompt: SessionRunner.QueuedPrompt) {
        id = prompt.id.uuidString
        text = prompt.text
        attachments = prompt.attachments.map(\.name)
    }
}

// A "full" change replaces the message outright. A "patch" carries only the fields it names:
// text to add to the end, and the tools whose contents moved.
struct RemoteChange: Encodable, Equatable {
    let kind: String
    let id: String
    var role: String?
    var date: Date?
    var text: String?
    var textAppend: String?
    var attachments: [String]?
    var blocks: [RemoteBlock]?
    var tools: [RemoteTool]?

    static func full(_ message: RemoteMessage) -> RemoteChange {
        RemoteChange(kind: "full", id: message.id, role: message.role, date: message.date,
                     text: message.text, attachments: message.attachments,
                     blocks: message.blocks)
    }

    static func patch(id: String, textAppend: String?, tools: [RemoteTool]?) -> RemoteChange {
        RemoteChange(kind: "patch", id: id, textAppend: textAppend, tools: tools)
    }
}

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

struct RemoteMessage: Encodable {
    let id: String
    let role: String
    let text: String
    let date: Date
    let attachments: [String]
    let blocks: [RemoteBlock]

    var tools: [RemoteTool] { blocks.flatMap { $0.tools ?? [] } }

    // Prose is already covered by the text digest. This only records the layout around
    // it, so an answer can still stream as small append patches while its last prose block
    // grows.
    var structureDigest: Int {
        var hasher = Hasher()
        for block in blocks {
            hasher.combine(block.kind)
            if block.kind == "thinking" { hasher.combine(block.text) }
            if block.kind == "tools" { block.tools?.forEach { hasher.combine($0.id) } }
        }
        return hasher.finalize()
    }

    init(_ message: ChatMessage, projectPath: String = "") {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        date = message.date
        attachments = (message.attachments ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
        blocks = message.blocks.map { RemoteBlock($0, projectPath: projectPath) }
    }
}

// The Mac has already rebuilt the separate text, thought and tool streams in their true
// order. Sending that result keeps the phone on the same ordering rules, including Unicode
// text offsets and calls made by child agents.
struct RemoteBlock: Encodable, Equatable {
    let kind: String
    let text: String?
    let tools: [RemoteTool]?

    init(_ block: MessageBlock, projectPath: String) {
        switch block {
        case .prose(_, let text):
            kind = "prose"
            self.text = text
            tools = nil
        case .thinking(_, let text):
            kind = "thinking"
            self.text = text
            tools = nil
        case .tools(_, let nodes):
            kind = "tools"
            text = nil
            tools = nodes
                .flatMap(Self.flatten)
                .sorted { $0.order < $1.order }
                .map { RemoteTool($0.tool, projectPath: projectPath) }
        }
    }

    private static func flatten(_ node: ToolNode) -> [ToolNode] {
        [node] + node.children.flatMap(flatten)
    }
}

struct RemoteTool: Encodable, Equatable {
    let id: String
    let name: String
    // The one argument the row is about, read the way the desktop spine reads it, so a
    // call names itself the same on both screens.
    let argument: String
    let added: Int?
    let input: String
    let result: String?
    let isError: Bool
    let isRunning: Bool

    var digest: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(input)
        hasher.combine(result)
        hasher.combine(isError)
        hasher.combine(isRunning)
        return hasher.finalize()
    }

    init(_ tool: ToolUse, projectPath: String = "") {
        let presentation = ToolPresentation(tool: tool, projectPath: projectPath)
        id = tool.id
        name = tool.name
        argument = presentation.argument
        added = presentation.added
        input = tool.input
        result = tool.result
        isError = tool.isError
        isRunning = tool.isRunning
    }
}

struct RemotePermission: Encodable {
    struct Question: Encodable {
        struct Option: Encodable {
            let label: String
            let description: String
        }

        let header: String
        let text: String
        let multiSelect: Bool
        let options: [Option]
    }

    let id: String
    // Which of the two asks this is, since the sheet names itself after it.
    let kind: String
    let toolName: String
    let title: String
    let lead: String
    let subject: String
    let detail: String
    // The branch the call would run on, or the project when the session has no worktree.
    let runsIn: String
    let alwaysTitle: String?
    let questions: [Question]

    init(_ request: PermissionRequest, runsIn: String) {
        id = request.id
        kind = request.isQuestion ? "question" : "permission"
        toolName = request.toolName
        title = request.title
        lead = request.toolName == "Bash"
            ? "The agent wants to run:"
            : "The agent wants to use \(request.title):"
        subject = request.subject
        detail = request.detail
        self.runsIn = runsIn
        alwaysTitle = request.alwaysTitle
        questions = request.questions.map {
            Question(header: $0.header, text: $0.text, multiSelect: $0.multiSelect,
                     options: $0.options.map {
                         Question.Option(label: $0.label, description: $0.description)
                     })
        }
    }
}

struct RemoteError: Encodable {
    let type = "error"
    let message: String
}
