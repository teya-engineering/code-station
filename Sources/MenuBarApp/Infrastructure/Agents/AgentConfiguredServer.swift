import Foundation
import CodeStationCore

// A server owned by an agent's configuration rather than Code Station's config file.
// Keeping it separate from Server prevents agent-owned servers from entering save,
// process, environment and bulk-sync paths that only apply to app-managed servers.
struct AgentConfiguredServer: Identifiable, Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case copilot

        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .copilot: "Copilot"
            }
        }

        var symbol: String {
            switch self {
            case .claudeCode: AgentKind.claudeCode.symbol
            case .codex: AgentKind.codex.symbol
            case .copilot: AgentKind.copilot.symbol
            }
        }

        // Claude Code keeps on and off per project, with no command to change it, so
        // only Codex and Copilot get a switch.
        var canSwitch: Bool { self != .claudeCode }

        // Only `claude mcp list` really connects to each server. The others report what
        // they would load, not whether it answers.
        var checksConnection: Bool { self == .claudeCode }

        var reloadNote: String {
            switch self {
            case .claudeCode: "Restart your Claude Code session to load the change."
            case .codex: "The next Codex turn loads the change."
            case .copilot: "The next Copilot turn loads the change."
            }
        }

        var command: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            case .copilot: "copilot"
            }
        }
    }

    // What an agent last said about reaching the server. Only Claude Code checks.
    enum Health: Equatable {
        case connected
        case needsSignIn
        case failed
    }

    enum Auth: Equatable {
        // The server asks for no sign-in, or the agent cannot sign in to it.
        case none
        case signedIn
        case signedOut
    }

    // Work in flight for one server in one agent.
    enum Work: Equatable {
        case checking
        case signingIn
        case turningOn
        case turningOff
    }

    enum Status: Equatable {
        case connected
        case on
        case needsSignIn
        case cantConnect
        case off
        case working(Work)

        var word: String {
            switch self {
            case .connected: "connected"
            case .on: "on"
            case .needsSignIn: "needs sign-in"
            case .cantConnect: "can't connect"
            case .off: "off"
            case .working(.checking): "checking…"
            case .working(.signingIn): "signing in…"
            case .working(.turningOn): "turning on…"
            case .working(.turningOff): "turning off…"
            }
        }

        // Higher is worse, so the detail header can show the one that matters most.
        var rank: Int {
            switch self {
            case .off: 1
            case .connected, .on: 2
            case .working: 3
            case .needsSignIn: 4
            case .cantConnect: 5
            }
        }

        var needsLook: Bool { rank >= 4 }

        // The sidebar names a status only when it asks for something or differs from
        // the quiet normal, so a list of healthy servers stays calm.
        var showsWordInSidebar: Bool {
            switch self {
            case .connected, .on: false
            case .needsSignIn, .cantConnect, .off, .working: true
            }
        }

        static func worst(_ statuses: [Status]) -> Status? {
            statuses.max { $0.rank < $1.rank }
        }
    }

    struct Registration: Identifiable, Equatable {
        let source: Source
        var command: String?
        var args: [String]
        var env: [String: String]
        var url: String?
        var type: String?
        var headers: [String: String]
        var enabled: Bool
        var auth: Auth = .none
        var health: Health?
        var work: Work?

        var id: Source { source }

        var transport: String {
            if command != nil { return "stdio" }
            guard let type, !type.isEmpty else { return url == nil ? "stdio" : "http" }
            return type == "streamable_http" ? "http" : type
        }

        var isRemote: Bool { transport != "stdio" }

        var status: Status {
            if let work { return .working(work) }
            if !enabled { return .off }
            if auth == .signedOut || health == .needsSignIn { return .needsSignIn }
            switch health {
            case .failed: return .cantConnect
            case .connected: return .connected
            case .needsSignIn, nil: return .on
            }
        }

        // Claude Code signs in to any remote server; Codex says per server whether it
        // can; Copilot has no sign-in command.
        var offersSignIn: Bool {
            switch source {
            case .claudeCode: isRemote
            case .codex: auth != .none
            case .copilot: false
            }
        }

        var signedIn: Bool {
            switch source {
            case .claudeCode: isRemote && health == .connected
            case .codex, .copilot: auth == .signedIn
            }
        }

        fileprivate var connection: Connection {
            Connection(command: command, args: args, env: env, url: url,
                       type: transport, headers: headers)
        }
    }

    fileprivate struct Connection: Equatable {
        var command: String?
        var args: [String]
        var env: [String: String]
        var url: String?
        var type: String
        var headers: [String: String]
    }

    let name: String
    let registrations: [Registration]

    var id: String { name }

    var hasDifferentConfigurations: Bool {
        guard let first = registrations.first?.connection else { return false }
        return registrations.dropFirst().contains { $0.connection != first }
    }

    func registration(from source: Source) -> Registration? {
        registrations.first { $0.source == source }
    }

    var worstStatus: Status? { Status.worst(registrations.map(\.status)) }

    static func outsideCodeStation(
        managedServers: [Server],
        claudeEntries: [String: ClaudeCodeManager.Entry],
        codexEntries: [String: CodexCodeManager.Entry],
        copilotEntries: [String: CopilotCodeManager.Entry] = [:],
        claudeHealth: [String: Health] = [:],
        work: (Source, String) -> Work? = { _, _ in nil }
    ) -> [Self] {
        let managedNames = Set(managedServers.map(\.name))
        let discoveredNames = Set(claudeEntries.keys)
            .union(codexEntries.keys)
            .union(copilotEntries.keys)
            .subtracting(managedNames)

        return discoveredNames.sorted().map { name in
            var registrations: [Registration] = []
            if let entry = claudeEntries[name] {
                registrations.append(Registration(
                    source: .claudeCode,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    url: entry.url,
                    type: entry.type,
                    headers: entry.headers,
                    enabled: true,
                    health: claudeHealth[name],
                    work: work(.claudeCode, name)))
            }
            if let entry = codexEntries[name] {
                registrations.append(Registration(
                    source: .codex,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    url: entry.url,
                    type: entry.type,
                    headers: [:],
                    enabled: entry.enabled,
                    auth: CodexCodeManager.auth(fromStatus: entry.authStatus),
                    work: work(.codex, name)))
            }
            if let entry = copilotEntries[name] {
                registrations.append(Registration(
                    source: .copilot,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    url: entry.url,
                    type: entry.type,
                    headers: entry.headers,
                    enabled: entry.enabled,
                    work: work(.copilot, name)))
            }
            return Self(name: name, registrations: registrations)
        }
    }
}
