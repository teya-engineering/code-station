import Foundation

// A project is just a folder on disk. A session runs Claude Code either directly in
// this directory or in a worktree of its own - see ChatSession.worktreePath.
struct Project: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path) }

    // Shown in the sidebar under the project name.
    var collapsedPath: String { path.abbreviatedPath }

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    // Folder name is a good enough default title.
    init(url: URL) {
        self.init(name: url.lastPathComponent, path: url.path)
    }
}

extension String {
    // "/Users/me/x" reads better as "~/x" anywhere a path is shown.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}

enum MessageRole: String, Codable {
    case user, assistant, system
}

// One tool call inside an assistant turn. `result` stays nil until Claude Code
// reports the tool_result, so the UI can show a call as still in flight.
struct ToolUse: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var input: String
    var result: String?
    var isError: Bool = false
    // How much of the turn's text had been written when this call started. It is the
    // only record of where the call belongs, since text and calls are kept apart.
    // Optional so conversations written before the app tracked it still decode; those
    // read as "before anything was said", which is how they have always been drawn.
    var textOffset: Int?

    var isRunning: Bool { result == nil }
}

// A run of the turn laid out in the order it happened: some text Claude wrote, or the
// calls it made at that point. Calls that started at the same point ran as one round,
// so they stay together and are drawn as a single spine.
enum MessageBlock: Identifiable {
    case prose(id: Int, text: String)
    case tools(id: Int, [ToolUse])

    var id: Int {
        switch self {
        case .prose(let id, _), .tools(let id, _): return id
        }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: MessageRole
    var text: String = ""
    var tools: [ToolUse] = []
    var date: Date = Date()
    // Paths of the files sent with a user turn. Optional so conversations written before
    // the app could take attachments still decode.
    var attachments: [String]?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tools.isEmpty
            && (attachments?.isEmpty ?? true)
    }

    // The turn put back together in the order it came in. The stream gives text and
    // calls as separate events and the app stores them apart, so this is what stops a
    // call the model made after speaking from being drawn above what it said.
    var blocks: [MessageBlock] {
        var blocks: [MessageBlock] = []
        // Where in the text the last block ended. Calls arrive in order, so this only
        // ever moves forwards - which is what lets the walk stay linear: the index
        // advances from where it is instead of being measured from the start each time.
        var cursor = 0
        var cursorIndex = text.startIndex
        let length = text.count
        var round: [ToolUse] = []

        func closeRound() {
            guard let first = round.first else { return }
            let end = min(max(first.textOffset ?? 0, cursor), length)
            if end > cursor {
                let endIndex = text.index(cursorIndex, offsetBy: end - cursor)
                blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex..<endIndex])))
                cursor = end
                cursorIndex = endIndex
            }
            blocks.append(.tools(id: blocks.count, round))
            round = []
        }

        for tool in tools {
            if let previous = round.first, (previous.textOffset ?? 0) != (tool.textOffset ?? 0) {
                closeRound()
            }
            round.append(tool)
        }
        closeRound()

        if cursor < length {
            blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex...])))
        }
        return blocks
    }
}

// Everything the sidebar says about a session whose transcript is not in memory. It is
// derived from the conversation and written beside it in the index, which is what lets
// a session be described without being loaded.
struct SessionSummary: Codable, Equatable {
    var lastMessageAt: Date?
    // The last call that finished, in the one-line form a row shows: "Bash · swift build".
    var lastTool: String?
    var added = 0
    var removed = 0

    // A whole shell command can be the label, and this one is written to the index for
    // every session. The row it ends up on is a single truncated line, so anything past
    // what could be read there is not worth keeping.
    private static let labelLimit = 120

    // Built from the whole transcript rather than kept up to date call by call: a result
    // lands long after the call that asked for it, and both numbers have to include it.
    @MainActor
    static func of(_ messages: [ChatMessage], projectPath: String) -> SessionSummary {
        var summary = SessionSummary(lastMessageAt: messages.last?.date)
        for tool in messages.flatMap(\.tools) {
            guard !tool.isRunning else { continue }
            let presentation = ToolPresentationCache.presentation(for: tool, projectPath: projectPath)
            if !tool.isError {
                summary.added += presentation.added ?? 0
                summary.removed += presentation.removed ?? 0
            }
            let label = presentation.label
            summary.lastTool = label.count > labelLimit
                ? String(label.prefix(labelLimit)) + "…"
                : label
        }
        return summary
    }
}

// A conversation with Claude Code in a project's directory. `claudeSessionID` is the
// id Claude Code itself reports in its init event; it is what `--resume` needs, so it
// is the one piece of state that must survive a restart of this app.
//
// The conversation itself is kept in a file of its own rather than in this record, so
// the app can hold every session it has ever had while only the open one costs anything.
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var projectID: UUID
    var title: String = "New session"
    var claudeSessionID: String?
    var createdAt: Date = Date()
    // Set when the session runs in its own git worktree instead of the project
    // folder. The worktree and branch belong to this session and go with it.
    var worktreePath: String?
    var worktreeBranch: String?
    // Optional so conversations written before the app had either still decode. Both
    // read as "nothing chosen yet" and "nothing spent yet".
    var settings: SessionSettings?
    var usage: SessionUsage?
    // Set when the agent opens a pull request from this session.
    var pullRequest: PullRequest?
    var summary = SessionSummary()

    // Empty until the store loads it, and empty again once nothing holds this session,
    // so nothing outside ProjectStore should reach for it: ask the store instead, which
    // is what guarantees there is a transcript here to read.
    var messages: [ChatMessage] = []
    var transcriptLoaded = false

    // When something last happened here, used for the sidebar's relative times.
    var lastActivity: Date { summary.lastMessageAt ?? createdAt }

    // The first thing the user asked makes a better title than "New session".
    mutating func retitleIfNeeded(from prompt: String) {
        guard title == "New session" else { return }
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !line.isEmpty else { return }
        title = line.count > 48 ? String(line.prefix(48)) + "…" : line
    }

    // The transcript is read and written on its own, so it is not part of what a session
    // encodes to. It is still decoded: a file written before the split holds every
    // conversation inline, and that is what the store moves out on the first launch.
    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, claudeSessionID, createdAt, worktreePath, worktreeBranch
        case settings, usage, pullRequest, summary, messages
    }

    init(id: UUID = UUID(), projectID: UUID) {
        self.id = id
        self.projectID = projectID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New session"
        claudeSessionID = try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        settings = try container.decodeIfPresent(SessionSettings.self, forKey: .settings)
        usage = try container.decodeIfPresent(SessionUsage.self, forKey: .usage)
        pullRequest = try container.decodeIfPresent(PullRequest.self, forKey: .pullRequest)
        summary = try container.decodeIfPresent(SessionSummary.self, forKey: .summary) ?? SessionSummary()
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        transcriptLoaded = !messages.isEmpty
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(claudeSessionID, forKey: .claudeSessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try container.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(pullRequest, forKey: .pullRequest)
        try container.encode(summary, forKey: .summary)
    }
}

enum SessionState: Equatable {
    case idle
    case starting
    case streaming
    case failed(String)

    var isBusy: Bool { self == .starting || self == .streaming }
}

// What the left sidebar can have selected.
enum SidebarSelection: Hashable {
    case session(UUID)
}
