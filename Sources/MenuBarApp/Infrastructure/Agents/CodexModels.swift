import Foundation
import Synchronization

// Codex exposes the models available to the signed-in account through its local app
// server. The exchange is short-lived and paginated so the picker reflects account and
// rollout changes without making the app depend on a hardcoded release list.
enum CodexModelReader {
    private static let framer = AgentMessageFramer(format: .jsonLines)

    static func read(at path: String, searchPath: String) async -> [ModelChoice.Option]? {
        guard let initialize = framer.frame([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "Teya", "version": "1"]],
        ]) else { return nil }

        let exchange = Exchange()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath

        guard (try? await CommandRunner.run(
            executable: path,
            arguments: ["app-server", "--stdio"],
            environment: environment,
            input: initialize,
            outputLineHandler: exchange.receive,
            timeout: .seconds(10),
            outputByteLimit: 1_048_576
        )) != nil else { return nil }
        return exchange.result
    }

    private final class Exchange: Sendable {
        private struct State {
            var requestID = 2
            var options: [ModelChoice.Option] = []
            var completed = false
            var failed = false
        }

        private let state = Mutex(State())

        var result: [ModelChoice.Option]? {
            state.withLock { state in
                guard state.completed, !state.failed else { return nil }
                var seen = Set<String>()
                return state.options.filter { option in
                    guard let id = option.id else { return false }
                    return seen.insert(id).inserted
                }
            }
        }

        func receive(_ line: String) -> CommandRunner.OutputLineAction {
            state.withLock { state in
                guard !state.completed, !state.failed,
                      let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let id = (message["id"] as? NSNumber)?.intValue else { return .none }

                func finishWithFailure() -> CommandRunner.OutputLineAction {
                    state.failed = true
                    return .finishProcess
                }

                if id == 1 {
                    guard message["error"] == nil,
                          let request = Self.request(id: state.requestID, cursor: nil)
                    else { return finishWithFailure() }
                    return .write(request)
                }

                guard id == state.requestID,
                      message["error"] == nil,
                      let response = message["result"] as? [String: Any],
                      let models = response["data"] as? [[String: Any]]
                else { return id == state.requestID ? finishWithFailure() : .none }

                state.options += models.compactMap(Self.option)
                if let cursor = response["nextCursor"] as? String, !cursor.isEmpty {
                    state.requestID += 1
                    guard let request = Self.request(id: state.requestID, cursor: cursor)
                    else { return finishWithFailure() }
                    return .write(request)
                }

                state.completed = true
                return .finishProcess
            }
        }

        private static func request(id: Int, cursor: String?) -> Data? {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            return framer.frame(["id": id, "method": "model/list", "params": params])
        }

        private static func option(_ raw: [String: Any]) -> ModelChoice.Option? {
            guard (raw["hidden"] as? Bool) != true else { return nil }
            let id = ((raw["model"] as? String) ?? (raw["id"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id, !id.isEmpty else { return nil }
            let title = (raw["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ModelChoice.shortName(of: id)
            let detail = (raw["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Available to this Codex account."
            let efforts = (raw["supportedReasoningEfforts"] as? [Any])?.compactMap { effort in
                if let effort = effort as? String { return effort }
                return (effort as? [String: Any])?["reasoningEffort"] as? String
            }
            return ModelChoice.Option(id: id, title: title, detail: detail,
                                      supportedEfforts: efforts,
                                      isDefault: (raw["isDefault"] as? Bool) == true)
        }
    }
}
