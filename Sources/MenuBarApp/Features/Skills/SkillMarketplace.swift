import Foundation

struct SkillMarketplace: Decodable, Equatable, Sendable {
    struct Plugin: Decodable, Equatable, Identifiable, Sendable {
        let name: String
        let description: String
        let version: String?
        let category: String?
        // Where the package's files sit, when it is kept in the marketplace's own
        // repository. A package fetched from elsewhere names an object here and reads nil.
        var source: String? = nil

        var marketplace = ""

        enum CodingKeys: String, CodingKey {
            case name, description, version, category, source
        }

        init(name: String, description: String, version: String?, category: String?,
             source: String? = nil, marketplace: String = "") {
            self.name = name
            self.description = description
            self.version = version
            self.category = category
            self.source = source
            self.marketplace = marketplace
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decode(String.self, forKey: .description)
            version = try container.decodeIfPresent(String.self, forKey: .version)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
        }

        var id: String { marketplace.isEmpty ? name : "\(name)@\(marketplace)" }
    }

    let name: String
    let description: String?
    let plugins: [Plugin]
}

struct SkillMarketplaceConfiguration: Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Equatable, Sendable {
        case gitRepository
        case localFile
    }

    let source: String
    let sourceKind: SourceKind
    let marketplace: String
    let label: String

    var isLocalFile: Bool { sourceKind == .localFile }
    var isValid: Bool { !source.isBlank && !marketplace.isBlank }

    static func siteDefault(_ skills: SiteDefaults.Skills) -> Self {
        Self(source: skills.repository,
             sourceKind: skills.sourceKind ?? .gitRepository,
             marketplace: skills.marketplace,
             label: skills.name)
    }
}

// The agents that install plugins from the marketplace. Claude Code, Codex and Copilot
// read the same marketplace format through their own plugin commands, so one catalogue
// serves every host and only the commands differ. Kiro has no plugin command: the app
// copies a package's skills to where Kiro loads them (see KiroSkillShelf).
enum SkillHost: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case copilot
    case kiro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .kiro: "Kiro"
        }
    }

    var command: String { self == .kiro ? AgentKind.kiro.command : rawValue }

    // Installed by copying files rather than through the agent's own commands, so the
    // argument lists below are never run for it.
    var copiesSkills: Bool { self == .kiro }

    // Copilot's `plugin list` has no JSON form; its `plugins` command lists everything it
    // has configured, plugins included, and does.
    var listArguments: [String] {
        switch self {
        case .claude, .codex: ["plugin", "list", "--json"]
        case .copilot: ["plugins", "list", "--json"]
        case .kiro: []
        }
    }

    var marketplaceListArguments: [String] {
        switch self {
        case .claude, .codex: ["plugin", "marketplace", "list", "--json"]
        case .copilot: ["plugin", "marketplace", "list"]
        case .kiro: []
        }
    }

    func marketplaceAddArguments(source: String) -> [String] {
        return switch self {
        case .claude, .copilot: ["plugin", "marketplace", "add", source]
        case .codex: ["plugin", "marketplace", "add", source, "--json"]
        case .kiro: []
        }
    }

    func marketplaceRefreshArguments(name: String) -> [String] {
        return switch self {
        case .claude, .copilot: ["plugin", "marketplace", "update", name]
        case .codex: ["plugin", "marketplace", "upgrade", name, "--json"]
        case .kiro: []
        }
    }

    func installArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "install", selector, "--scope", "user"]
        case .codex: ["plugin", "add", selector, "--json"]
        case .copilot: ["plugin", "install", selector]
        case .kiro: []
        }
    }

    func removeArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "uninstall", selector, "--scope", "user"]
        case .codex: ["plugin", "remove", selector, "--json"]
        case .copilot: ["plugin", "uninstall", selector]
        case .kiro: []
        }
    }

    func updateArguments(plugin: String, marketplace: String) -> [String] {
        let selector = "\(plugin)@\(marketplace)"
        return switch self {
        case .claude: ["plugin", "update", selector, "--scope", "user"]
        // Adding an installed Codex plugin reconciles its cached version with the
        // refreshed marketplace snapshot.
        case .codex: ["plugin", "add", selector, "--json"]
        case .copilot: ["plugin", "update", selector]
        case .kiro: []
        }
    }
}

struct SkillInstallation: Equatable, Sendable {
    let version: String
    let enabled: Bool
}

enum SkillsRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneDay = 1
    case fiveDays = 5
    case thirtyDays = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "Every 1 day"
        case .fiveDays: "Every 5 days"
        case .thirtyDays: "Every 30 days"
        }
    }

    nonisolated func shouldRefresh(lastRefresh: Date?, now: Date = Date()) -> Bool {
        guard self != .never else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= TimeInterval(rawValue * 86_400)
    }
}

enum SkillActionProgress: String, Equatable, Sendable {
    case checkingMarketplace = "Checking marketplace…"
    case addingMarketplace = "Adding marketplace…"
    case refreshingMarketplace = "Refreshing marketplace…"
    case installing = "Installing package…"
    case uninstalling = "Uninstalling package…"
    case updating = "Updating package…"
    case checkingInstallation = "Checking installation…"
}
