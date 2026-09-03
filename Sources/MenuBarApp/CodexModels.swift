import Foundation

// Codex exposes the models available to the signed-in account through its local app
// server. The exchange is short-lived and paginated so the picker reflects account and
// rollout changes without making the app depend on a hardcoded release list.
enum CodexModelReader {
    static func read(at path: String, searchPath: String) async -> [ModelChoice.Option]? {
        guard let initialize = messageData([
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

    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID = 2
        private var options: [ModelChoice.Option] = []
        private var completed = false
        private var failed = false

        var result: [ModelChoice.Option]? {
            lock.withLock {
                guard completed, !failed else { return nil }
                var seen = Set<String>()
                return options.filter { option in
                    guard let id = option.id else { return false }
                    return seen.insert(id).inserted
                }
            }
        }

        func receive(_ line: String) -> CommandRunner.OutputLineAction {
            lock.withLock {
                guard !completed, !failed,
                      let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let id = (message["id"] as? NSNumber)?.intValue else { return .none }

                if id == 1 {
                    guard message["error"] == nil,
                          let request = Self.request(id: requestID, cursor: nil)
                    else { return finishWithFailure() }
                    return .write(request)
                }

                guard id == requestID,
                      message["error"] == nil,
                      let response = message["result"] as? [String: Any],
                      let models = response["data"] as? [[String: Any]]
                else { return id == requestID ? finishWithFailure() : .none }

                options += models.compactMap(Self.option)
                if let cursor = response["nextCursor"] as? String, !cursor.isEmpty {
                    requestID += 1
                    guard let request = Self.request(id: requestID, cursor: cursor)
                    else { return finishWithFailure() }
                    return .write(request)
                }

                completed = true
                return .finishProcess
            }
        }

        private func finishWithFailure() -> CommandRunner.OutputLineAction {
            failed = true
            return .finishProcess
        }

        private static func request(id: Int, cursor: String?) -> Data? {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            return messageData(["id": id, "method": "model/list", "params": params])
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

    private static func messageData(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}
