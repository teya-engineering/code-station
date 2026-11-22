import Foundation

// One tool call inside an assistant turn. `result` stays nil until Claude Code
// reports the tool_result, so the UI can show a call as still in flight.
struct ToolUse: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var input: String
    var result: String?
    var isError: Bool = false
    // Shell calls carry the process result when the agent reports one. Other failures
    // still use `isError`, since not every tool has an exit status.
    var exitCode: Int?
    // How much of the turn's text had been written when this call started. It is the
    // only record of where the call belongs, since text and calls are kept apart.
    // Optional so conversations written before the app tracked it still decode; those
    // read as "before anything was said", which is how they have always been drawn.
    var textOffset: Int?
    // The call that started the agent which made this one, when it was not the main
    // loop that made it. Every call of a whole fan-out arrives in the same flat stream,
    // so this is the only thing that says which agent was working.
    var parentID: String?
    // The last thing an agent said while it worked, kept only for the call that started
    // it. A fan-out can run for many minutes with nothing else to show for it.
    var status: String?
    // Where in the file an edit landed, counted from 1. No CLI says, so it is read
    // off disk the moment the call reports in, while what is on disk is still what the
    // call wrote. Nil when the file could not be read or the call was not an edit, which
    // is what leaves a diff without a line gutter.
    var editStartLine: Int?
    // What the call left behind on disk when its input did not say. Filled in once the
    // snapshot behind it comes back, which is a beat after the result. Nil when the input
    // describes the change and when the call changed nothing.
    var written: WrittenChange?
    // When the call reached the app. No CLI sends a time, so it is stamped as the
    // call arrives. Optional so conversations written before the app kept it still
    // decode; those fall back to the time of the turn they sit in.
    var startedAt: Date?
    // When the call's result reached the app, stamped the same way. Nil while the call
    // runs, and for a call interrupted mid-turn, which never reports in.
    var finishedAt: Date?
    var agentTask: AgentTaskRecord?

    var isRunning: Bool { result == nil }

    // How long the call took, from its arrival to its result. Nil until it has reported
    // in, and for conversations written before the app kept both times.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    // Calls that stand for an agent rather than for work done in this conversation.
    // Their rows read as a container: what matters is what ran inside them.
    static let agentTools: Set<String> = ["Task", "Agent", "Workflow"]

    var startsAgents: Bool { Self.agentTools.contains(name) }

    // The id the CLI gave the agent this call started, read off the receipt it answered
    // with. An agent sent to the background reports in the moment it starts, so the
    // call's own result says nothing about whether the agent is still working. This is
    // what ties the call to the list of agents the CLI says are still going.
    var backgroundAgentID: String? {
        if let agentTask { return agentTask.task.id }
        guard startsAgents, let result,
              let marker = result.range(of: "agentId: ") else { return nil }
        let id = result[marker.upperBound...].prefix { $0.isHexDigit }
        return id.isEmpty ? nil : String(id)
    }

    // Calls that may arrive carrying the change they made. Codex can send only the paths,
    // so the name alone does not say whether the payload is enough to draw the change.
    static let editTools: Set<String> = ["Edit", "Write", "Delete"]

    var describesOwnChange: Bool {
        guard Self.editTools.contains(name),
              let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)),
              let fields = object as? [String: Any]
        else { return false }
        if let diff = fields["diff"] as? String, !diff.isEmpty { return true }
        return switch name {
        case "Edit": fields["old_string"] is String && fields["new_string"] is String
        case "Write": fields["content"] is String
        default: false
        }
    }
}

struct AgentTaskRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case running, finished, completed, failed, interrupted
    }

    var task: BackgroundTask
    var state: State = .running
    var report: String?
    var finishedAt: Date?
}

// A change git saw a call make, worked out by comparing the working tree before and after
// it ran. Kept with the call rather than derived again on demand: the trees it came from
// are unreachable the moment they are taken, and the worktree itself may be gone by the
// time anyone reads the conversation back.
struct WrittenChange: Codable, Equatable, Sendable {
    var files = 0
    var added = 0
    var removed = 0
    // The change itself, as a unified patch covering every file. Nil when it was too large
    // to be worth reading inline, which leaves the counts above and nothing to unfold.
    var patch: String?
}
