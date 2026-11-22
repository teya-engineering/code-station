import SwiftUI

enum SettingsSearchTarget: String, Hashable {
    case generalSidebar
    case generalOldSessions
    case generalOrphanedWorktrees
    case generalStats
    case generalSkills
    case generalSystem
    case sessionsMidTurnPrompts
    case sessionsSuggestions
    case sessionsRecaps
    case sessionsTitles
    case sessionsSound
    case sessionsMemory
    case appearanceTheme
    case appearanceSunlight
    case appearanceCursorEffects
    case appearanceText
    case appearanceMessages
    case appearanceTimestamps
    case appearanceHeaderButtons
    case appearanceSidebarIcons
    case appearanceDefaultBot
    case keyboardShortcuts
    case agentDefault
    case agentConfigure
    case agentDetails
    case agentUsage
    case agentModel
    case agentEffort
    case agentPermissions
    case agentCost
    case agentFiles
    case secondOpinionReviewers
    case secondOpinionFocus
    case secondOpinionReading
    case secondOpinionAccess
    case advancedConfiguration
    case advancedImport
    case advancedSessionLog
    case mobileAccess
    case mobilePairingLifetime

    var id: String { rawValue }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let title: String
    let tab: SettingsTab
    let target: SettingsSearchTarget
    let keywords: String
    var agent: AgentKind?

    var id: String {
        [tab.title, agent?.title, title].compactMap { $0 }.joined(separator: ":")
    }
}

enum SettingsSearchIndex {
    static let entries = [
        result("Terminal", .general, .generalSystem,
               "system open shell command app"),
        result("Open in", .general, .generalSystem,
               "system open folder editor app finder cursor vscode jetbrains add remove"),
        result("Start at login", .general, .generalSystem,
               "system launch log in startup"),
        result("Sessions shown", .general, .generalSidebar,
               "sidebar recent project workspace see more limit"),
        result("Skills refresh", .general, .generalSkills,
               "skills marketplace refresh versions interval daily"),
        result("Old sessions", .general, .generalOldSessions,
               "count old after days delete automatically on their own review clear stale design saved work uncommitted unpushed commits ask me first confirm unread snoozed park"),
        result("Orphaned worktrees", .general, .generalOrphanedWorktrees,
               "git checkout prune automatically treat like old sessions no session disk cleanup uncommitted branch"),
        result("Stats", .general, .generalStats,
               "stats statistics turn on off enable count time cost live past removed deleted sessions days history retention"),
        result("Prompts sent during a turn", .sessions, .sessionsMidTurnPrompts,
               "steer queue send now wait mid turn running busy return enter interrupt"),
        result("Automatic session recaps", .sessions, .sessionsRecaps,
               "recap catch up return summary conversation finish away manual toggle"),
        result("Automatic session titles", .sessions, .sessionsTitles,
               "title name rename regenerate summarise sentence first turn right click manual toggle"),
        result("Suggest the next prompt", .sessions, .sessionsSuggestions,
               "suggestion suggest next prompt predict composer follow up autocomplete toggle"),
        result("Session finished sound", .sessions, .sessionsSound,
               "sound alert audio chime beep play finish turn ends notification silent off"),
        result("Session memory", .sessions, .sessionsMemory,
               "limit ram gigabytes gb stop turn protect mac build automatic out of memory"),
        result("Theme", .appearance, .appearanceTheme,
               "appearance system light dark macos"),
        result("Sunlight", .appearance, .appearanceSunlight,
               "appearance sun sunset sunrise warm warmth night flux kelvin colour temperature always fixed"),
        result("Cursor effects", .appearance, .appearanceCursorEffects,
               "appearance pointer sparks ember aurora orbit ripple water rings prism facets spectral none animation always running show"),
        result("Session text", .appearance, .appearanceText,
               "appearance size small regular large transcript diff terminal"),
        result("Your messages", .appearance, .appearanceMessages,
               "appearance colour color bubble prompt sent project icon stone paper lemon leaf ink"),
        result("Timestamps", .appearance, .appearanceTimestamps,
               "appearance time timestamp stamp clock date when sent seconds smart message step tool hover"),
        result("Header buttons", .appearance, .appearanceHeaderButtons,
               "appearance session toolbar rail dock show hide preview globe running app browser"),
        result("Sidebar icons", .appearance, .appearanceSidebarIcons,
               "appearance style monogram dicebear avatar motion breathing"),
        result("Your bots", .appearance, .appearanceDefaultBot,
               "appearance default avatar image personality picture photo add edit remove delete collection crew"),
        result("Keyboard shortcuts", .keyboard, .keyboardShortcuts,
               "keys key command cmd control ctrl option shift escape reference list bindings change rebind customise customize record reset"),
        result("Back and forward", .keyboard, .keyboardShortcuts,
               "previous next session project workspace history navigate bracket retrace"),
        result("Default agent", .agents, .agentDefault,
               "claude code codex copilot new sessions"),
        result("Configure agent", .agents, .agentConfigure,
               "switch account settings claude code codex copilot"),
        result("Claude Code account", .agents, .agentDetails,
               "connected refresh version plan path sign in login", agent: .claudeCode),
        result("Codex account", .agents, .agentDetails,
               "connected refresh auth version plan path sign in login", agent: .codex),
        result("Claude Code usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .claudeCode),
        result("Codex usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .codex),
        result("Copilot account", .agents, .agentDetails,
               "connected refresh github version path sign in login", agent: .copilot),
        result("Copilot usage", .agents, .agentUsage,
               "premium requests github", agent: .copilot),
        result("Model", .agents, .agentModel,
               "default opus sonnet haiku fable sol terra luna auto gpt"),
        result("Effort", .agents, .agentEffort,
               "thinking default low medium high extra max"),
        result("Permissions", .agents, .agentPermissions,
               "accept edits ask risky manual sandbox access"),
        result("Cost", .agents, .agentCost,
               "spent dollars session usage show"),
        result("Agent files", .agents, .agentFiles,
               "claude settings json codex config toml copilot reveal"),
        result("Usual reviewers", .secondOpinion, .secondOpinionReviewers,
               "second opinion review reviewer lineup seat ask default model effort claude codex copilot"),
        result("Look for", .secondOpinion, .secondOpinionFocus,
               "second opinion review focus bugs edge cases security tests risks assumptions steps hierarchy accessibility copy states"),
        result("They read", .secondOpinion, .secondOpinionReading,
               "second opinion review project files conversation design source html handoff theme"),
        result("Use your MCP servers", .secondOpinion, .secondOpinionAccess,
               "second opinion review reviewer mcp servers tools access read only logs dashboards docs"),
        result("Current configuration", .advanced, .advancedConfiguration,
               "json environments api access credentials oauth shared defaults starter requests mcp presets skills marketplace shortcuts export backup"),
        result("Import", .advanced, .advancedImport,
               "import backup restore reset repository url github load choose file aspects team configuration"),
        result("Move to another Mac", .advanced, .advancedImport,
               "export import backup restore laptop migrate transfer new computer"),
        result("Session log", .advanced, .advancedSessionLog,
               "system open reveal stuck diagnostics debug troubleshoot"),
        result("Mobile access", .mobile, .mobileAccess,
               "qr code phone wifi remote share iphone android"),
        result("Keep a code working", .mobile, .mobilePairingLifetime,
               "qr code phone session expire expiry revoke timeout idle lifetime duration last how long")
    ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let words = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        return entries.enumerated().filter { _, entry in
            let haystack = "\(entry.title) \(entry.tab.title) \(entry.keywords)".lowercased()
            return words.allSatisfy(haystack.contains)
        }
        .sorted { lhs, rhs in
            let leftRank = rank(lhs.element, phrase: phrase, words: words)
            let rightRank = rank(rhs.element, phrase: phrase, words: words)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }
        .map(\.element)
    }

    private static func rank(_ entry: SettingsSearchResult,
                             phrase: String,
                             words: [String]) -> Int {
        let title = entry.title.lowercased()
        if title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        if title.contains(phrase) { return 2 }
        if words.allSatisfy(title.contains) { return 3 }
        return 4
    }

    private static func result(_ title: String,
                               _ tab: SettingsTab,
                               _ target: SettingsSearchTarget,
                               _ keywords: String,
                               agent: AgentKind? = nil) -> SettingsSearchResult {
        SettingsSearchResult(title: title,
                             tab: tab,
                             target: target,
                             keywords: keywords,
                             agent: agent)
    }
}

enum SettingsTab: CaseIterable, Hashable {
    case general
    case sessions
    case appearance
    case keyboard
    case agents
    case secondOpinion
    case mobile
    case advanced

    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .appearance: "Appearance"
        case .keyboard: "Keyboard"
        case .agents: "Agents"
        case .secondOpinion: "Second opinion"
        case .mobile: "Mobile"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .appearance: "paintpalette"
        case .keyboard: "keyboard"
        case .agents: "cpu"
        case .secondOpinion: "checkmark.rectangle.stack"
        case .mobile: "iphone"
        case .advanced: "gearshape"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Code Station."
        case .sessions: "How a session behaves while its agent works, and what happens when a turn ends."
        case .appearance: "Make Code Station comfortable to read and easy to recognise at a glance."
        case .keyboard: "Every key Code Station answers. Click a key to change it."
        case .agents: "Choose an agent and set how it runs."
        case .secondOpinion: "Who reads your work when you ask for a second opinion, what they look for, and what they can reach."
        case .mobile: "Read and run your sessions from a phone on the same Wi-Fi."
        case .advanced: "Manage shared configuration and other advanced settings."
        }
    }
}
