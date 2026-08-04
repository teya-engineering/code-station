import Foundation

// A project is just a folder on disk. Unlike Conductor there is no worktree and no
// copy: every session for a project runs Claude Code directly in this directory, so
// only one session can be live at a time.
struct Project: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
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

    var isRunning: Bool { result == nil }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: MessageRole
    var text: String = ""
    var tools: [ToolUse] = []
    var date: Date = Date()

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tools.isEmpty }
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
