import Foundation

enum MessageRole: String, Codable, Sendable {
    case user, assistant, system, instructions
}

// One tool call inside an assistant turn. `result` stays nil until Claude Code
// reports the tool_result, so the UI can show a call as still in flight.
struct ToolUse: Identifiable, Codable, Equatable, Sendable {
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
    // The call that started the agent which made this one, when it was not the main
    // loop that made it. Every call of a whole fan-out arrives in the same flat stream,
    // so this is the only thing that says which agent was working.
    var parentID: String?
    // The last thing an agent said while it worked, kept only for the call that started
    // it. A fan-out can run for many minutes with nothing else to show for it.
    var status: String?
    // Where in the file an edit landed, counted from 1. Neither CLI says, so it is read
    // off disk the moment the call reports in, while what is on disk is still what the
    // call wrote. Nil when the file could not be read or the call was not an edit, which
    // is what leaves a diff without a line gutter.
    var editStartLine: Int?
    // What the call left behind on disk, for a call whose own input does not say. Filled
    // in once the snapshot behind it comes back, which is a beat after the result. Nil for
    // an edit, which describes its own change, and for a call that changed nothing.
    var written: WrittenChange?
    // When the call reached the app. Neither CLI sends a time, so it is stamped as the
    // call arrives. Optional so conversations written before the app kept it still
    // decode; those fall back to the time of the turn they sit in.
    var startedAt: Date?
    // When the call's result reached the app, stamped the same way. Nil while the call
    // runs, and for a call interrupted mid-turn, which never reports in.
    var finishedAt: Date?

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
        guard startsAgents, let result,
              let marker = result.range(of: "agentId: ") else { return nil }
        let id = result[marker.upperBound...].prefix { $0.isHexDigit }
        return id.isEmpty ? nil : String(id)
    }

    // Calls that arrive carrying the change they are about to make. Everything else has to
    // be measured against the working tree to know what it did.
    static let editTools: Set<String> = ["Edit", "Write", "Delete"]
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

// One call and everything that ran inside it. A turn's calls are stored flat, in the
// order the stream gave them, and this is that list read as what it really is.
struct ToolNode: Identifiable {
    let tool: ToolUse
    var children: [ToolNode] = []
    // Where the call sat in the turn's flat list, which is the order it happened in.
    // Kept so the newest call of a whole subtree can be found again once the list has
    // been folded into a tree and the order between branches is gone.
    var order = 0

    var id: String { tool.id }

    // Every call inside this one, however deep.
    var callCount: Int { children.reduce(children.count) { $0 + $1.callCount } }

    // Every call inside this one that stood up an agent, counted as deep as calls are.
    var agentCount: Int {
        children.reduce(0) { $0 + ($1.tool.startsAgents ? 1 : 0) + $1.agentCount }
    }

    // Read by the folded block, which has to flag a failure it is otherwise hiding.
    var hasError: Bool { tool.isError || children.contains(where: \.hasError) }

    // Also read by the folded block, which stays open while there is work to watch. An
    // agent sent to the background hands back its own result at once and keeps going, so
    // its call reporting in is not the end of it: only the CLI's own list of the agents
    // still running says when that is.
    func isWorking(agents: Set<String>) -> Bool {
        if tool.isRunning { return true }
        if let id = tool.backgroundAgentID, agents.contains(id) { return true }
        return children.contains { $0.isWorking(agents: agents) }
    }

    // The newest call anywhere inside this one: what the agents are doing right now.
    var newestDescendant: ToolNode? {
        children.flatMap { [$0] + ($0.newestDescendant.map { [$0] } ?? []) }
            .max { $0.order < $1.order }
    }
}

// One stretch of the model's reasoning, kept apart from what it said out loud. The
// offsets record where in the turn it happened, the same way a tool call carries its
// text offset, so the turn can be read back in the order it ran.
struct ThinkingSegment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var text: String
    // How much of the turn's text had been written when this arrived.
    var textOffset = 0
    // How many calls the turn had made when this arrived. Text alone cannot place a
    // thought between two rounds of calls that spoke no words between them.
    var toolOffset = 0
}

// A run of the turn laid out in the order it happened: some text Claude wrote, a stretch
// of thinking, or the calls it made at that point. Adjacent calls that started at the
// same point ran as one round, so they stay together and are drawn as a single spine.
enum MessageBlock: Identifiable {
    case prose(id: Int, text: String)
    case thinking(id: Int, text: String)
    case tools(id: Int, [ToolNode])

    var id: Int {
        switch self {
        case .prose(let id, _), .thinking(let id, _), .tools(let id, _): return id
        }
    }
}

// The resume ids as they stood before a prompt ran, written on that prompt's message.
// Claude Code forks a new id on every resumed turn, so an id recorded here keeps
// pointing at the conversation as it was then - which is what makes rewinding to the
// message, or forking a new session from it, possible. Codex reuses one thread for the
// whole conversation, so a Codex turn cannot be wound back; the agent that ran the
// turn is recorded to tell the two apart.
struct ConversationCheckpoint: Codable, Equatable, Sendable {
    var agent: AgentKind
    var claudeSessionID: String?
    var codexSessionID: String?
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var role: MessageRole
    var text: String = ""
    var tools: [ToolUse] = []
    var date: Date = Date()
    // Paths of the files sent with a user turn. Optional so conversations written before
    // the app could take attachments still decode.
    var attachments: [String]?
    // The model's reasoning, in the order it happened. Optional so conversations written
    // before the app kept thinking still decode.
    var thinking: [ThinkingSegment]?
    // Where the conversation stood when this prompt ran. Only prompts that start a turn
    // carry one; a prompt sent into a turn already running does not mark a point the
    // conversation could go back to.
    var checkpoint: ConversationCheckpoint?

    var isEmpty: Bool {
        text.isBlank
            && tools.isEmpty
            && (attachments?.isEmpty ?? true)
            && (thinking?.isEmpty ?? true)
    }

    // The turn's calls read as a tree: a call an agent made hangs under the call that
    // started that agent. A child whose parent is not in the turn is left at the top
    // level rather than dropped, so a stream that lost an event still shows the work.
    var toolTree: [ToolNode] {
        let positions = Dictionary(tools.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        var childrenOf: [String: [ToolUse]] = [:]
        var roots: [ToolUse] = []
        for tool in tools {
            if let parent = tool.parentID, parent != tool.id, positions[parent] != nil {
                childrenOf[parent, default: []].append(tool)
            } else {
                roots.append(tool)
            }
        }
        // Only a root can be reached from a root, and a call has one parent, so a chain
        // that pointed back at itself would sit outside this walk entirely - it cannot
        // recur forever.
        func node(_ tool: ToolUse) -> ToolNode {
            ToolNode(tool: tool,
                     children: (childrenOf[tool.id] ?? []).map(node),
                     order: positions[tool.id] ?? 0)
        }
        return roots.map(node)
    }

    // The turn put back together in the order it came in. The stream gives text, thinking
    // and calls as separate events and the app stores them apart, so this is what stops a
    // call the model made after speaking from being drawn above what it said.
    var blocks: [MessageBlock] {
        var blocks: [MessageBlock] = []
        // Where in the text the last block ended. Calls and thoughts arrive in order, so
        // this only ever moves forwards - which is what lets the walk stay linear: the
        // index advances from where it is instead of being measured from the start.
        var cursor = 0
        var cursorIndex = text.startIndex
        let length = text.count

        func emitProse(upTo offset: Int) {
            let end = min(max(offset, cursor), length)
            guard end > cursor else { return }
            let endIndex = text.index(cursorIndex, offsetBy: end - cursor)
            blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex..<endIndex])))
            cursor = end
            cursorIndex = endIndex
        }

        // Both lists are already in the order they happened, so this is a plain merge.
        // A thought that arrived before a call goes ahead of it. It also ends the prior
        // round, even when no prose was written between the calls.
        var thoughts = ArraySlice(thinking ?? [])
        func emitThoughts(beforeText textOffset: Int, tool toolOrder: Int) {
            while let thought = thoughts.first,
                  thought.textOffset < textOffset
                    || (thought.textOffset == textOffset && thought.toolOffset <= toolOrder) {
                emitProse(upTo: thought.textOffset)
                blocks.append(.thinking(id: blocks.count, text: thought.text))
                thoughts.removeFirst()
            }
        }

        // Only the calls the main loop made set the shape of the turn. What ran inside
        // an agent is drawn under the call that started it, wherever that call sits.
        for node in toolTree {
            let textOffset = node.tool.textOffset ?? 0
            emitThoughts(beforeText: textOffset, tool: node.order)
            emitProse(upTo: textOffset)

            // Adjacent calls at the same text offset were one round. A thought or prose
            // block between them keeps separate steps separate.
            if case .tools(let id, var round)? = blocks.last,
               (round.first?.tool.textOffset ?? 0) == textOffset {
                round.append(node)
                blocks[blocks.count - 1] = .tools(id: id, round)
            } else {
                blocks.append(.tools(id: blocks.count, [node]))
            }
        }
        for thought in thoughts {
            emitProse(upTo: thought.textOffset)
            blocks.append(.thinking(id: blocks.count, text: thought.text))
        }

        if cursor < length {
            blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex...])))
        }
        return blocks
    }
}
