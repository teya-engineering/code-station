import Foundation

// A project is just a folder on disk. Unlike Conductor there is no worktree and no
// copy: every session for a project runs Claude Code directly in this directory, so
// only one session can be live at a time.
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
        return replacingOccurrences(of: home, with: "~")
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
        // ever moves forwards.
        var cursor = 0
        var round: [ToolUse] = []

        func closeRound() {
            guard let first = round.first else { return }
            let end = min(max(first.textOffset ?? 0, cursor), text.count)
            if end > cursor {
                blocks.append(.prose(id: blocks.count, text: slice(cursor, end)))
                cursor = end
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

        if cursor < text.count {
            blocks.append(.prose(id: blocks.count, text: slice(cursor, text.count)))
        }
        return blocks
    }

    private func slice(_ from: Int, _ to: Int) -> String {
        let start = text.index(text.startIndex, offsetBy: from)
        let end = text.index(text.startIndex, offsetBy: to)
        return String(text[start..<end])
    }
}

// A conversation with Claude Code in a project's directory. `claudeSessionID` is the
// id Claude Code itself reports in its init event; it is what `--resume` needs, so it
// is the one piece of state that must survive a restart of this app.
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var projectID: UUID
    var title: String = "New session"
    var claudeSessionID: String?
    var messages: [ChatMessage] = []
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

    // When something last happened here, used for the sidebar's relative times.
    var lastActivity: Date { messages.last?.date ?? createdAt }

    // The first thing the user asked makes a better title than "New session".
    mutating func retitleIfNeeded(from prompt: String) {
        guard title == "New session" else { return }
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !line.isEmpty else { return }
        title = line.count > 48 ? String(line.prefix(48)) + "…" : line
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
