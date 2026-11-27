import Foundation
import Observation

// The pane is about the agents the app can run: which one sessions use, whether its CLI
// is there, who it is signed in as, and where its own files live. The account details
// come straight from each CLI's own files where it keeps them there, which keeps
// opening the pane instant. Versions, Codex account usage and Copilot's sign-in need a
// process, so they arrive when they arrive.
@MainActor
@Observable
final class ClaudeAgentInfo {
    struct Account {
        var name: String?
        var email: String
        var organization: String?
        var plan: String?
    }

    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: Account?
    private(set) var isCheckingVersion = false
    private(set) var versionCheckFailed = false
    @ObservationIgnored private var versionTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        path = ProcessManager.resolve("claude")
        account = Self.readAccount()
        version = nil
        isCheckingVersion = false
        versionCheckFailed = false
        guard let path else { return }
        isCheckingVersion = true
        let searchPath = ProcessManager.searchPath
        versionTask = Task {
            // The CLI prints "2.1.220 (Claude Code)"; the number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").first.map(String.init)
            guard !Task.isCancelled else { return }
            self.version = version
            self.versionCheckFailed = version == nil
            self.isCheckingVersion = false
        }
    }

    var readiness: AgentReadiness {
        AgentReadiness(installed: path != nil, signedIn: account != nil,
                       checking: isCheckingVersion, failed: versionCheckFailed)
    }

    // MARK: - Private

    private static func readAccount() -> Account? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String else { return nil }
        return Account(name: oauth["displayName"] as? String,
                       email: email,
                       organization: oauth["organizationName"] as? String,
                       plan: planName(oauth["organizationType"] as? String))
    }

    private static func planName(_ type: String?) -> String? {
        switch type {
        case "claude_max": "Claude Max"
        case "claude_pro": "Claude Pro"
        case "claude_team": "Claude Team"
        case "claude_enterprise": "Claude Enterprise"
        default: type?.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// The same story for Codex. Its sign-in lives in ~/.codex/auth.json: a ChatGPT login
// leaves OAuth tokens there, an API-key login leaves the key, and the account details
// ride inside the id token's claims.
@MainActor
@Observable
final class CodexAgentInfo {
    struct Account {
        var method: String
        var email: String?
        var plan: String?
    }

    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: Account?
    private(set) var usage: CodexUsage?
    private(set) var isRefreshingUsage = false
    private var refreshID = UUID()
    private(set) var isCheckingVersion = false
    private(set) var versionCheckFailed = false
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        usageTask?.cancel()
        path = ProcessManager.resolve("codex")
        account = Self.readAccount()
        version = nil
        isCheckingVersion = false
        versionCheckFailed = false
        usage = nil
        isRefreshingUsage = false
        refreshID = UUID()
        guard let path else { return }
        isCheckingVersion = true
        let searchPath = ProcessManager.searchPath
        let id = refreshID
        versionTask = Task {
            // The CLI prints "codex-cli 0.52.0"; the number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").last.map(String.init)
            guard !Task.isCancelled, refreshID == id else { return }
            self.version = version
            self.versionCheckFailed = version == nil
            self.isCheckingVersion = false
        }
        guard account != nil else { return }
        isRefreshingUsage = true
        usageTask = Task {
            let usage = await CodexUsageReader.read(at: path, searchPath: searchPath)
            guard !Task.isCancelled, refreshID == id else { return }
            self.usage = usage
            self.isRefreshingUsage = false
        }
    }

    var readiness: AgentReadiness {
        AgentReadiness(installed: path != nil, signedIn: account != nil,
                       checking: isCheckingVersion, failed: versionCheckFailed)
    }

    static func readAccount() -> Account? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return account(from: obj)
    }

    // Split from the file read so the parsing is testable.
    static func account(from obj: [String: Any]) -> Account? {
        if let tokens = obj["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let claims = claims(fromJWT: idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            return Account(method: "ChatGPT login",
                           email: claims["email"] as? String,
                           plan: planName(auth?["chatgpt_plan_type"] as? String))
        }
        if let key = obj["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return Account(method: "API key", email: nil, plan: nil)
        }
        return nil
    }

    // The middle piece of a JWT is the claims, base64url-encoded JSON. No signature
    // check: this is the CLI's own file being read back, not something to verify.
    static func claims(fromJWT token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var body = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func planName(_ type: String?) -> String? {
        switch type {
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro"
        case "team": "ChatGPT Team"
        case "free": "Free"
        default: type?.capitalized
        }
    }
}

// Copilot keeps its sign-in in the system keychain or takes it from the gh CLI, so the
// only honest way to read it is to ask the CLI. That takes a moment, like its version.
@MainActor
@Observable
final class CopilotAgentInfo {
    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: CopilotServer.AuthStatus?
    private(set) var isCheckingAccount = false
    private(set) var accountCheckFailed = false
    private var refreshID = UUID()
    private(set) var isCheckingVersion = false
    private(set) var versionCheckFailed = false
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        accountTask?.cancel()
        path = ProcessManager.resolve("copilot")
        version = nil
        isCheckingVersion = false
        versionCheckFailed = false
        account = nil
        isCheckingAccount = false
        accountCheckFailed = false
        refreshID = UUID()
        guard let path else { return }
        isCheckingVersion = true
        let searchPath = ProcessManager.searchPath
        let id = refreshID
        versionTask = Task {
            // The CLI prints "GitHub Copilot CLI 1.0.83." and a line about updates; the
            // number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(whereSeparator: \.isNewline).first?
                .split(separator: " ").last
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            guard !Task.isCancelled, refreshID == id else { return }
            self.version = version
            self.versionCheckFailed = version == nil
            self.isCheckingVersion = false
        }
        isCheckingAccount = true
        accountTask = Task {
            let status = await CopilotServer.authStatus(at: path, searchPath: searchPath)
            guard !Task.isCancelled, refreshID == id else { return }
            self.account = status?.isAuthenticated == true ? status : nil
            self.accountCheckFailed = status == nil
            self.isCheckingAccount = false
        }
    }

    var readiness: AgentReadiness {
        AgentReadiness(installed: path != nil, signedIn: account != nil,
                       checking: isCheckingVersion || isCheckingAccount,
                       failed: versionCheckFailed || accountCheckFailed)
    }
}

// Kiro says who is signed in through `kiro-cli whoami`. Its sign-in sits in Kiro's own
// database rather than the keychain, so asking never waits on a system prompt.
@MainActor
@Observable
final class KiroAgentInfo {
    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: KiroCLI.Account?
    private(set) var isCheckingAccount = false
    private(set) var accountCheckFailed = false
    // What the CLI said when its answer could not be read, shown in place of a guess.
    private(set) var accountProblem: String?
    private(set) var isCheckingVersion = false
    private(set) var versionCheckFailed = false
    private var refreshID = UUID()
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        accountTask?.cancel()
        path = ProcessManager.resolve(AgentKind.kiro.command)
        version = nil
        account = nil
        isCheckingVersion = false
        versionCheckFailed = false
        isCheckingAccount = false
        accountCheckFailed = false
        accountProblem = nil
        refreshID = UUID()
        guard let path else { return }
        let searchPath = ProcessManager.searchPath
        let id = refreshID
        isCheckingVersion = true
        versionTask = Task {
            // The CLI prints "kiro-cli 3.5.0"; the number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(whereSeparator: \.isNewline).first?
                .split(separator: " ").last.map(String.init)
            guard !Task.isCancelled, refreshID == id else { return }
            self.version = version
            self.versionCheckFailed = version == nil
            self.isCheckingVersion = false
        }
        isCheckingAccount = true
        accountTask = Task {
            let reading = await KiroCLI.account(at: path, searchPath: searchPath)
            guard !Task.isCancelled, refreshID == id else { return }
            switch reading {
            case .signedIn(let account): self.account = account
            case .signedOut: break
            case .unknown(let said):
                self.accountCheckFailed = true
                self.accountProblem = "Could not read the sign-in"
                    + (said.map { ": \($0)" } ?? ". Refresh to ask Kiro again.")
            }
            self.isCheckingAccount = false
        }
    }

    var readiness: AgentReadiness {
        AgentReadiness(installed: path != nil, signedIn: account != nil,
                       checking: isCheckingVersion || isCheckingAccount,
                       failed: versionCheckFailed || accountCheckFailed)
    }
}

// One agent's account, read through the same info object the Agents pane uses, for a
// screen that only cares about the agent its session runs on.
@MainActor
enum AgentAccount {
    case claudeCode(ClaudeAgentInfo)
    case codex(CodexAgentInfo)
    case copilot(CopilotAgentInfo)
    case kiro(KiroAgentInfo)

    init(_ agent: AgentKind) {
        switch agent {
        case .claudeCode: self = .claudeCode(ClaudeAgentInfo())
        case .codex: self = .codex(CodexAgentInfo())
        case .copilot: self = .copilot(CopilotAgentInfo())
        case .kiro: self = .kiro(KiroAgentInfo())
        }
    }

    func refresh() {
        switch self {
        case .claudeCode(let info): info.refresh()
        case .codex(let info): info.refresh()
        case .copilot(let info): info.refresh()
        case .kiro(let info): info.refresh()
        }
    }

    // Nil until the answer is in. Copilot has to be asked, and a check that could not
    // reach it says nothing either way about the sign-in.
    var signedIn: Bool? {
        switch self {
        case .claudeCode(let info): info.path == nil ? nil : info.account != nil
        case .codex(let info): info.path == nil ? nil : info.account != nil
        case .copilot(let info):
            info.path == nil || info.isCheckingAccount || info.accountCheckFailed
                ? nil : info.account != nil
        case .kiro(let info):
            info.path == nil || info.isCheckingAccount || info.accountCheckFailed
                ? nil : info.account != nil
        }
    }

    // Who it is signed in as, worded the way the Agents pane words it.
    var summary: String? {
        switch self {
        case .claudeCode(let info):
            info.account.map { account in
                account.name.map { "\($0) · \(account.email)" } ?? account.email
            }
        case .codex(let info):
            info.account.map { account in
                account.email.map { "\(account.method) · \($0)" } ?? account.method
            }
        case .copilot(let info):
            info.account?.summary
        case .kiro(let info):
            info.account?.summary
        }
    }
}

// Runs "<cli> --version" and hands back the line it printed.
nonisolated func cliVersion(at path: String, searchPath: String) async -> String? {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPath
    guard let output = try? await CommandRunner.run(
        executable: path,
        arguments: ["--version"],
        environment: env,
        timeout: .seconds(5),
        outputByteLimit: 65_536
    ), output.succeeded else { return nil }
    let trimmed = output.output.trimmed
    return trimmed.isEmpty ? nil : trimmed
}
