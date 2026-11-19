import Foundation
import SQLite3

// What `kiro-cli` says about the account and its models. Both are plain commands that
// print JSON and exit, and the sign-in sits in Kiro's own database rather than the
// keychain, so asking does not stop on a system prompt the way Copilot's can.
enum KiroCLI {
    struct Account: Equatable, Sendable {
        var accountType: String?
        var provider: String?
        var email: String?
        var startURL: String?

        init(accountType: String? = nil, provider: String? = nil, email: String? = nil,
             startURL: String? = nil) {
            self.accountType = accountType
            self.provider = provider
            self.email = email
            self.startURL = startURL
        }

        // The account's own fields, under "account" or at the top level. Kiro names them
        // differently for each way of signing in, so every likely spelling is read.
        init(fields: [String: Any]) {
            let fields = fields["account"] as? [String: Any] ?? fields
            func text(_ keys: String...) -> String? {
                keys.lazy.compactMap { (fields[$0] as? String)?.trimmed }.first { !$0.isEmpty }
            }
            self.init(accountType: text("accountType", "account_type", "authType", "type"),
                      provider: text("provider", "identityProvider", "socialProvider"),
                      email: text("email", "userEmail", "username"),
                      startURL: text("startUrl", "startURL", "start_url", "issuerUrl"))
        }

        // `kiro-cli whoami` without a format: "Logged in with GitHub" and "Email: …".
        init(text: String) {
            var account = Account()
            for line in text.split(whereSeparator: \.isNewline).map({ String($0).trimmed }) {
                if let range = line.range(of: "Logged in with ", options: .caseInsensitive) {
                    account.provider = String(line[range.upperBound...]).trimmed
                } else if line.lowercased().hasPrefix("email:") {
                    account.email = String(line.dropFirst("email:".count)).trimmed
                }
            }
            self = account
        }

        // How the sign-in reads on the account row: who, and through what.
        var summary: String {
            guard let who = email ?? startURL.flatMap({ URL(string: $0)?.host }) else { return method }
            return "\(who) · \(method)"
        }

        var method: String {
            let words = [accountType, provider].compactMap { $0?.lowercased() }.joined(separator: " ")
            if words.contains("identitycenter") || words.contains("identity center")
                || words.contains("idc") || words.contains("sso") || startURL != nil {
                return "via IAM Identity Center"
            }
            if words.contains("organization") { return "via your organisation's sign-in" }
            if words.contains("builder") { return "via AWS Builder ID" }
            if words.contains("apikey") || words.contains("api_key") || words.contains("api key") {
                return "via an API key"
            }
            if let provider, !provider.isEmpty { return "via \(provider)" }
            if words.contains("social") { return "via GitHub or Google" }
            if let accountType, !accountType.isEmpty { return "via \(accountType)" }
            return "Signed in to Kiro"
        }
    }

    enum AccountReading: Equatable, Sendable {
        case signedIn(Account)
        case signedOut
        // The answer could not be read. The CLI's own words come along, so the account
        // row can show what it said rather than guess.
        case unknown(String?)
    }

    // Who is signed in, asked two ways. `whoami` names the account but does not speak for
    // every kind of sign-in: an organisation's sign-in is reported as nobody at all. Kiro's
    // own database holds a token for whichever way was used and loses it on logout, so a
    // token there is a sign-in whatever `whoami` said.
    static func account(at path: String, searchPath: String) async -> AccountReading {
        let stored = storedSignIn()
        let asked: AccountReading
        if let output = await run(path, ["whoami", "--format", "json"], searchPath: searchPath) {
            asked = reading(status: output.status, output: output.output, errorOutput: output.errorOutput)
        } else {
            asked = .unknown(nil)
        }
        return combined(asked: asked, stored: stored)
    }

    static func combined(asked: AccountReading, stored: AccountReading?) -> AccountReading {
        switch (asked, stored) {
        case (.signedIn(var account), .signedIn(let kept)?):
            // The database knows the way in when whoami's answer did not say.
            if account.method == "Signed in to Kiro" { account.accountType = kept.accountType }
            return .signedIn(account)
        case (.signedIn, _): return asked
        case (_, .signedIn?): return stored ?? asked
        // A key in the environment signs in without anything in the database, so only
        // whoami can say there is nobody.
        default: return asked
        }
    }

    // The sign-in Kiro keeps in its own database: an `auth_kv` table with one row per
    // token, named by the way in - "kirocli:social:token" for GitHub or Google,
    // "kirocli:odic:token" for an organisation's sign-in. Only the names are read, never
    // the tokens. Nil when the database cannot be read, which says nothing either way.
    static func storedSignIn(database: URL = defaultDatabase) -> AccountReading? {
        var handle: OpaquePointer?
        guard FileManager.default.fileExists(atPath: database.path),
              sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key FROM auth_kv", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            if let text = sqlite3_column_text(statement, 0) { keys.append(String(cString: text)) }
        }
        let tokens = keys.map { $0.lowercased() }.filter { $0.hasSuffix(":token") }
        guard !tokens.isEmpty else { return .signedOut }
        if tokens.contains(where: { $0.contains(":odic:") || $0.contains(":oidc:") }) {
            return .signedIn(Account(accountType: "Organization"))
        }
        if tokens.contains(where: { $0.contains(":social:") }) {
            return .signedIn(Account(accountType: "Social"))
        }
        return .signedIn(Account())
    }

    static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }

    // What `whoami --format json` said. The exit status is the surest part of the answer:
    // Kiro exits 0 for a signed-in account, whatever it then prints about it, and 1 with
    // {"account":null} for nobody. The JSON is looked for on any line, since a notice
    // about updates or a profile can come before it.
    static func reading(status: Int32, output: String, errorOutput: String) -> AccountReading {
        let object = jsonObject(in: output)
        if let object, object.keys.contains("account"), object["account"] is NSNull { return .signedOut }
        if status == 0 {
            var account = object.map(Account.init(fields:)) ?? Account()
            if account == Account() { account = Account(text: output) }
            return .signedIn(account)
        }
        let said = [errorOutput, output].joined(separator: "\n")
        if said.range(of: "not logged in", options: .caseInsensitive) != nil
            || said.range(of: "please log in", options: .caseInsensitive) != nil {
            return .signedOut
        }
        let firstLine = said.split(whereSeparator: \.isNewline).map { String($0).trimmed }
            .first { !$0.isEmpty }
        return .unknown(firstLine)
    }

    private static func jsonObject(in text: String) -> [String: Any]? {
        let candidates = [text] + text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.trimmed.hasPrefix("{") }
        for candidate in candidates {
            if let object = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    static func models(at path: String, searchPath: String) async -> [ModelChoice.Option]? {
        guard let output = await run(path, ["chat", "--list-models", "--format", "json"],
                                     searchPath: searchPath), output.succeeded
        else { return nil }
        return options(in: Data(output.output.utf8))
    }

    // The picker's rows for what Kiro listed. Each model costs a multiple of the plan's
    // credits, which is what tells two otherwise similar models apart, so it is shown.
    static func options(in data: Data) -> [ModelChoice.Option]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        let preferred = object["default_model"] as? String
        var seen = Set<String>()
        let options = models.compactMap { raw -> ModelChoice.Option? in
            guard let id = (raw["model_id"] as? String)?.trimmed, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let title = id == "auto" ? "Auto" : Self.title(of: id)
            var detail = id == "auto" ? "Kiro picks the model for each request."
                : (raw["description"] as? String)?.trimmed ?? "Available to this Kiro account."
            if let rate = raw["rate_multiplier"] as? Double, rate > 0 {
                // Kiro's descriptions end without a full stop.
                if let last = detail.last, !".!?".contains(last) { detail += "." }
                detail += " \(rate.formatted(.number.precision(.fractionLength(0...2))))× credits."
            }
            return ModelChoice.Option(id: id, title: title, detail: detail,
                                      isDefault: id == preferred)
        }
        return options.isEmpty ? nil : options
    }

    // "qwen3-coder-next" reads as "Qwen3 Coder Next" and "glm-5" as "GLM 5".
    static func title(of id: String) -> String {
        let names = ["glm": "GLM", "gpt": "GPT", "deepseek": "DeepSeek", "minimax": "MiniMax"]
        return id.split(separator: "-").map { part in
            names[part.lowercased()] ?? part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    private static func run(_ path: String, _ arguments: [String],
                            searchPath: String) async -> CommandRunner.Output? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        return try? await CommandRunner.run(executable: path, arguments: arguments,
                                            environment: environment,
                                            timeout: .seconds(30), outputByteLimit: 1_048_576)
    }
}
