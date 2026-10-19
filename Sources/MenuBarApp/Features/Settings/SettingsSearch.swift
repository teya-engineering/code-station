import SwiftUI
import CodeStationCore

enum SettingsSearchTarget: String, Hashable {
    case generalSidebar
    case generalRecaps
    case generalTitles
    case generalSuggestions
    case generalSound
    case generalOldSessions
    case generalOrphanedWorktrees
    case generalSessionMemory
    case generalDesign
    case generalSkills
    case generalSystem
    case appearanceTheme
    case appearanceWorkingSet
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
    case advancedConfiguration
    case advancedReset
    case experimentalFeatures

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
        result("Sessions shown", .general, .generalSidebar,
               "sidebar recent project workspace see more limit"),
        result("Automatic session recaps", .general, .generalRecaps,
               "recap catch up return summary conversation finish away manual toggle"),
        result("Automatic session titles", .general, .generalTitles,
               "title name rename regenerate summarise sentence first turn right click manual toggle"),
        result("Suggest the next prompt", .general, .generalSuggestions,
               "suggestion suggest next prompt predict composer follow up autocomplete toggle"),
        result("Session finished sound", .general, .generalSound,
               "sound alert audio chime beep play finish turn ends notification silent off"),
        result("Old sessions", .general, .generalOldSessions,
               "count old after days delete automatically review clear stale design saved work uncommitted"),
        result("Orphaned worktrees", .general, .generalOrphanedWorktrees,
               "git checkout prune automatically no session disk cleanup uncommitted branch"),
        result("Session memory", .general, .generalSessionMemory,
               "limit ram gigabytes gb stop turn protect mac build automatic out of memory"),
        result("Design ambition", .general, .generalDesign,
               "design restrained balanced all out showcase polish bold style canvas default"),
        result("Skills refresh", .general, .generalSkills,
               "skills marketplace refresh versions interval daily"),
        result("Terminal", .general, .generalSystem,
               "system open shell command app"),
        result("Start at login", .general, .generalSystem,
               "system launch log in startup"),
        result("Session log", .general, .generalSystem,
               "system open reveal stuck diagnostics"),
        result("Theme", .appearance, .appearanceTheme,
               "appearance system light dark macos"),
        result("Session text", .appearance, .appearanceTheme,
               "appearance size small regular large transcript diff terminal"),
        result("Your messages", .appearance, .appearanceTheme,
               "appearance colour color bubble prompt sent project icon stone paper lemon leaf ink"),
        result("Open working set automatically", .appearance, .appearanceWorkingSet,
               "appearance session layout panel sidebar default first turn agent closed open"),
        result("Sidebar icons", .appearance, .appearanceSidebarIcons,
               "appearance style monogram dicebear motion still animated"),
        result("Your bots", .appearance, .appearanceDefaultBot,
               "appearance default avatar image personality picture photo add edit remove delete collection crew"),
        result("Keyboard shortcuts", .keyboard, .keyboardShortcuts,
               "keys key command cmd control ctrl option shift escape reference list bindings"),
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
        result("Current configuration", .advanced, .advancedConfiguration,
               "json environments api access credentials oauth shared defaults starter requests mcp presets skills marketplace shortcuts"),
        result("Reset from file", .advanced, .advancedReset,
               "repository url github load choose file restore aspects"),
        result("Mobile access", .experimental, .experimentalFeatures,
               "qr code phone wifi experimental")
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
    case appearance
    case keyboard
    case agents
    case advanced
    case experimental

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .keyboard: "Keyboard"
        case .agents: "Agents"
        case .advanced: "Advanced"
        case .experimental: "Experimental"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .keyboard: "keyboard"
        case .agents: "cpu"
        case .advanced: "gearshape"
        case .experimental: "flask"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Code Station."
        case .appearance: "Make Code Station comfortable to read and easy to recognise at a glance."
        case .keyboard: "Every key Code Station answers, and what it does."
        case .agents: "Choose an agent and set how it runs."
        case .advanced: "Manage shared configuration and other advanced settings."
        case .experimental: "Try features that are still in development."
        }
    }
}
