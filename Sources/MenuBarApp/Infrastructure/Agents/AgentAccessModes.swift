import Foundation

// The permission modes Claude Code takes, minus the ones that have no place in a desktop
// app: nothing here can turn every check off. Stored as its raw value, which is the word
// the CLI's --permission-mode flag takes.
enum PermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case acceptEdits, manual, auto, plan

    static let fallback: PermissionMode = .acceptEdits

    // Plan mode is for one piece of work, and approving the plan ends it. As the app-wide
    // default it would make every new session read-only, so it is not offered there.
    static let defaultChoices = allCases.filter { $0 != .plan }

    // The mode a session goes back to once its plan is approved. A stored plan mode is
    // skipped, or approving the plan would start the next turn planning all over again.
    static func afterPlan(_ stored: PermissionMode?) -> PermissionMode {
        let mode = stored ?? .fallback
        return mode == .plan ? .fallback : mode
    }

    // The fallback stands in for nothing chosen and for a mode the app no longer offers.
    init(stored: String?) {
        self = stored.flatMap(PermissionMode.init(rawValue:)) ?? .fallback
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acceptEdits: "Accept edits, ask about the rest"
        case .manual: "Ask about everything"
        case .auto: "Ask only about risky things"
        case .plan: "Plan first, change nothing"
        }
    }

    // What the mode is called where a sentence does not fit, like the composer bar.
    var shortTitle: String {
        switch self {
        case .acceptEdits: "Allow edits"
        case .manual: "Every step"
        case .auto: "Risky only"
        case .plan: "Plan only"
        }
    }

    var detail: String {
        switch self {
        case .acceptEdits:
            "Edits to files go through on their own. Commands and anything else are asked about."
        case .manual:
            "Every edit and every command waits for an answer. The slowest, and the one that shows the most."
        case .auto:
            "Claude Code judges each step and only asks about the ones that can do damage."
        case .plan:
            "Claude Code reads and plans but changes nothing. Approving the plan puts the session back in its usual mode."
        }
    }
}

// Codex `exec` has no way to send a permission question back through the JSONL stream,
// so the app offers the access modes it can apply consistently to new and resumed turns.
// Full access is needed for local services such as a GPG agent.
enum CodexSandboxMode: String, Codable, Sendable, CaseIterable {
    case workspaceWrite = "workspace-write"
    case approveForMe = "approve-for-me"
    case fullAccess = "danger-full-access"

    var title: String {
        switch self {
        case .workspaceWrite: "Sandboxed"
        case .approveForMe: "Sandboxed + auto-approve"
        case .fullAccess: "Full access"
        }
    }

    var summary: String {
        switch self {
        case .approveForMe: "Sandboxed + auto"
        default: title
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite:
            "Can edit this session's files. Internet, GPG, and other services outside the workspace stay blocked."
        case .approveForMe:
            "Keeps the sandbox. Codex can automatically approve a retry outside it when needed."
        case .fullAccess:
            "Runs without file, local service, or network restrictions. Use only with projects you trust."
        }
    }

    static func valid(_ value: String?) -> Self? {
        value.flatMap(Self.init(rawValue:))
    }

    static func resolved(_ value: String?) -> Self {
        valid(value) ?? .workspaceWrite
    }
}

// Copilot tools run with the access policy selected for the session. The server
// enforces the same path and URL limits for initial prompts and follow-ups.
enum CopilotAccessMode: String, Codable, Sendable, CaseIterable {
    case workspace = "workspace"
    case fullAccess = "full-access"

    var title: String {
        switch self {
        case .workspace: "Workspace only"
        case .fullAccess: "Full access"
        }
    }

    var summary: String { title }

    var detail: String {
        switch self {
        case .workspace:
            "Tools run without asking inside this session's folders. Files elsewhere and web addresses stay blocked."
        case .fullAccess:
            "Any file, any web address, no confirmation. Use only with projects you trust."
        }
    }

    static func valid(_ value: String?) -> Self? {
        value.flatMap(Self.init(rawValue:))
    }

    static func resolved(_ value: String?) -> Self {
        valid(value) ?? .workspace
    }
}
