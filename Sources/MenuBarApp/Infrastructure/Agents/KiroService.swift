import Foundation

// How the person signs in to Kiro. Kiro's own menu covers GitHub, Google, AWS Builder ID
// and an organisation's external identity provider, such as Okta or Microsoft Entra ID.
// IAM Identity Center is the one way in that needs details the menu cannot guess: the
// organisation's start URL and the AWS region it lives in. Kept on the Mac rather than in
// site configuration, since every organisation has its own.
struct KiroSignIn: Equatable, Sendable {
    enum Method: String, CaseIterable, Sendable {
        case kiroMenu = "menu"
        case identityCenter = "identity-center"

        var title: String {
            switch self {
            case .kiroMenu: "Kiro's sign-in menu"
            case .identityCenter: "IAM Identity Center"
            }
        }

        var detail: String {
            switch self {
            case .kiroMenu:
                "GitHub, Google, AWS Builder ID, or your organisation's identity provider, chosen in Kiro's own menu."
            case .identityCenter:
                "Your organisation's AWS single sign-on. Ask your administrator for the start URL and region."
            }
        }
    }

    var method: Method = .kiroMenu
    var startURL = ""
    var region = ""

    // The command the sign-in window runs. Identity Center details that are not yet
    // usable fall back to Kiro's menu, which offers Identity Center too, so the button
    // never runs a command that can only fail.
    var command: String {
        guard method == .identityCenter, problem == nil else { return "kiro-cli login" }
        return ["kiro-cli", "login", "--license", "pro",
                "--identity-provider", startURL.trimmed, "--region", region.trimmed]
            .map(\.shellQuoted).joined(separator: " ")
    }

    // What is wrong with the Identity Center details, worded for the field it is about.
    var problem: String? {
        guard method == .identityCenter else { return nil }
        let url = startURL.trimmed
        if url.isEmpty { return "Enter your organisation's start URL." }
        guard let parsed = URL(string: url), parsed.scheme == "https",
              let host = parsed.host, host.contains(".") else {
            return "The start URL begins with https://, for example https://d-1234567890.awsapps.com/start."
        }
        let region = region.trimmed
        if region.isEmpty { return "Enter the AWS region, for example us-east-1." }
        guard Self.looksLikeRegion(region) else {
            return "That does not look like an AWS region. It reads like us-east-1 or eu-west-2."
        }
        return nil
    }

    // us-east-1, eu-central-2, us-gov-west-1, ap-southeast-3.
    static func looksLikeRegion(_ text: String) -> Bool {
        text.range(of: #"^[a-z]{2}(-[a-z]+)+-\d{1,2}$"#, options: .regularExpression) != nil
    }

    static func stored(in store: UserDefaults = .standard) -> KiroSignIn {
        KiroSignIn(method: store.string(forKey: Keys.method).flatMap(Method.init(rawValue:)) ?? .kiroMenu,
                   startURL: store.string(forKey: Keys.startURL) ?? "",
                   region: store.string(forKey: Keys.region) ?? "")
    }

    func store(in store: UserDefaults = .standard) {
        store.set(method.rawValue, forKey: Keys.method)
        store.set(startURL.trimmed, forKey: Keys.startURL)
        store.set(region.trimmed, forKey: Keys.region)
    }

    private enum Keys {
        static let method = "kiroSignInMethod"
        static let startURL = "kiroIdentityCenterStartURL"
        static let region = "kiroIdentityCenterRegion"
    }
}

// What `kiro-cli` says about the account and its models. Both are plain commands that
// print JSON and exit, and the sign-in sits in Kiro's own database rather than the
// keychain, so asking does not stop on a system prompt the way Copilot's can.
enum KiroCLI {
    struct Account: Equatable, Sendable {
        var accountType: String?
        var provider: String?
        var email: String?

        // `whoami --format json` prints {"account":null} when nobody is signed in, and the
        // account's own fields when someone is.
        init?(whoami data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  !object.keys.contains("account") || !(object["account"] is NSNull) else { return nil }
            let fields = object["account"] as? [String: Any] ?? object
            accountType = Self.text(fields["accountType"])
            provider = Self.text(fields["provider"])
            email = Self.text(fields["email"])
            guard accountType != nil || provider != nil || email != nil else { return nil }
        }

        // How the sign-in reads on the account row: who, and through what.
        var summary: String {
            let how = method
            guard let email else { return how }
            return "\(email) · \(how)"
        }

        var method: String {
            let type = accountType?.lowercased() ?? ""
            if type.contains("identitycenter") || type.contains("idc") || type.contains("sso") {
                return "via IAM Identity Center"
            }
            if type.contains("builder") { return "via AWS Builder ID" }
            if type.contains("apikey") || type.contains("api_key") { return "via an API key" }
            if let provider, !provider.isEmpty { return "via \(provider)" }
            return "Kiro login"
        }

        private static func text(_ value: Any?) -> String? {
            guard let value = value as? String, !value.trimmed.isEmpty else { return nil }
            return value.trimmed
        }
    }

    enum AccountReading: Equatable, Sendable {
        case signedIn(Account)
        case signedOut
        // The CLI could not be asked, which says nothing about the sign-in either way.
        case unknown
    }

    static func account(at path: String, searchPath: String) async -> AccountReading {
        guard let output = await run(path, ["whoami", "--format", "json"], searchPath: searchPath)
        else { return .unknown }
        if let account = Account(whoami: Data(output.output.utf8)) { return .signedIn(account) }
        return output.output.contains("\"account\"") ? .signedOut : .unknown
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
