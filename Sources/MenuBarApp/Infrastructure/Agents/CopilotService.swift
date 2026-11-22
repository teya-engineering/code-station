import Foundation
import Synchronization

// Copilot answers questions about the account and its models through a headless server
// built into the CLI: the same JSON-RPC exchange its own SDK uses. A read starts one,
// asks, and stops it, so the settings pane and the model picker reflect the account
// without starting a coding session or sending a prompt.
enum CopilotServer {
    // Who the CLI is signed in as. Copilot takes its login from its own sign-in, from the
    // gh CLI, or from a token in the environment, and says which.
    struct AuthStatus: Equatable, Sendable {
        var isAuthenticated: Bool
        var login: String?
        var method: String?
        var statusMessage: String?

        init?(response: [String: Any]) {
            guard let isAuthenticated = response["isAuthenticated"] as? Bool else { return nil }
            self.isAuthenticated = isAuthenticated
            login = Self.text(response["login"])
            method = Self.text(response["authType"])
            statusMessage = Self.text(response["statusMessage"])
        }

        // How the sign-in reads on the account row.
        var summary: String? {
            guard isAuthenticated else { return nil }
            let how = switch method {
            case "gh-cli": "via the gh CLI"
            case "env", "token", "api-key": "via a token"
            default: "Copilot login"
            }
            guard let login, !login.isEmpty else { return how }
            return "\(login) · \(how)"
        }

        private static func text(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    // Starting the CLI can stop on a system prompt asking to unlock the keychain the
    // sign-in is kept in. Killing it while that prompt is up cancels the read waiting
    // behind it, and an "Always Allow" answered after that is never recorded, so the
    // prompt returns on every later read. Any wait therefore has to outlast a person
    // reading a dialog and typing a password. It is here only to catch a CLI that never
    // answers at all, and nothing is waiting on the result in the meantime.
    static let replyTimeout = Duration.seconds(180)

    static func authStatus(at path: String, searchPath: String) async -> AuthStatus? {
        guard let result = await request("auth.getStatus", at: path, searchPath: searchPath)
        else { return nil }
        return AuthStatus(response: result)
    }

    static func models(at path: String, searchPath: String) async -> [ModelChoice.Option]? {
        guard let result = await request("models.list", at: path, searchPath: searchPath)
        else { return nil }
        return options(in: result)
    }

    // The picker's rows for what the server listed. A model the account has switched off
    // is left out: choosing it would only fail at the first turn.
    static func options(in response: [String: Any]) -> [ModelChoice.Option]? {
        guard let models = response["models"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let options = models.compactMap { raw -> ModelChoice.Option? in
            guard let id = (raw["id"] as? String)?.trimmed, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let policy = raw["policy"] as? [String: Any]
            guard policy?["state"] as? String != "disabled" else { return nil }
            let title = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ModelChoice.shortName(of: id)
            let efforts = (raw["supportedReasoningEfforts"] as? [Any])?
                .compactMap { $0 as? String }
            return ModelChoice.Option(id: id, title: title,
                                      detail: detail(for: id, category: raw["modelPickerCategory"] as? String),
                                      supportedEfforts: efforts)
        }
        return options.isEmpty ? nil : options
    }

    // MARK: - Private

    private static func detail(for id: String, category: String?) -> String {
        if id == "auto" { return "Copilot picks the model for each request." }
        return switch category {
        case "powerful": "The strongest reasoning, and the slowest."
        case "versatile": "The everyday balance of speed and depth."
        case "lightweight", "fast": "The fastest and cheapest; best for small, mechanical work."
        default: "Available to this Copilot account."
        }
    }

    // One request and its answer. The server frames every message the way a language
    // server does, with a byte count in a header rather than a newline at the end, so
    // the answer is read off the raw output rather than line by line.
    private static func request(_ method: String, at path: String,
                                searchPath: String) async -> [String: Any]? {
        guard let message = AgentMessageFramer(format: .contentLength)
            .frame(["jsonrpc": "2.0", "id": 1, "method": method, "params": [String: Any]()])
        else { return nil }
        let exchange = Exchange(id: 1)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath

        guard (try? await CommandRunner.run(
            executable: path,
            arguments: ["--headless", "--stdio", "--no-auto-update", "--log-level", "none"],
            environment: environment,
            input: message,
            outputChunkAction: exchange.receive,
            timeout: replyTimeout,
            outputByteLimit: 4_194_304
        )) != nil else { return nil }
        return exchange.result
    }

    // Collects the framed replies until the one with the awaited id arrives, then asks
    // for the server to be stopped. Chunks land on a background queue, hence the lock.
    private final class Exchange: Sendable {
        private struct State {
            var framer = AgentMessageFramer(format: .contentLength)
            // The awaited reply as it arrived. It is read as JSON on the way out, since
            // a JSON object cannot be handed from one thread to another.
            var reply: Data?
        }

        private let id: Int
        private let state = Mutex(State())

        init(id: Int) { self.id = id }

        var result: [String: Any]? {
            guard let reply = state.withLock({ $0.reply }) else { return nil }
            let message = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            return message?["result"] as? [String: Any] ?? [:]
        }

        // A header the framer cannot make sense of drops what is buffered, so one bad
        // frame does not hold the read up until the timeout.
        func receive(_ chunk: Data) -> CommandRunner.OutputLineAction {
            state.withLock { state in
                guard state.reply == nil else { return .none }
                state.framer.append(chunk)
                while let body = try? state.framer.next() {
                    let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                    guard (message?["id"] as? NSNumber)?.intValue == id else { continue }
                    state.reply = body
                    return .finishProcess
                }
                return .none
            }
        }
    }
}
