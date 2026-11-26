import Foundation

// The envelope is stable across both servers. Agent-specific payloads stay tolerant
// of extra fields so a CLI update cannot make an unrelated event fail to decode.
struct AgentRPCMessage {
    struct Failure {
        let message: String
    }

    let id: Any?
    let method: String?
    let params: [String: Any]
    let result: [String: Any]
    let error: Failure?

    init(_ object: [String: Any]) {
        id = object["id"]
        method = object["method"] as? String
        params = object["params"] as? [String: Any] ?? [:]
        result = object["result"] as? [String: Any] ?? [:]
        error = (object["error"] as? [String: Any]).map {
            Failure(message: $0["message"] as? String ?? "Unknown protocol error.")
        }
    }
}

struct AgentRequestTracker<Request> {
    private var nextID = 0
    private var pending: [Int: (request: Request, started: Date)] = [:]

    var values: [Request] { pending.values.map(\.request) }

    mutating func insert(_ request: Request, at date: Date) -> Int {
        nextID += 1
        pending[nextID] = (request, date)
        return nextID
    }

    mutating func remove(_ id: Int) -> Request? {
        pending.removeValue(forKey: id)?.request
    }

    func hasExpired(at date: Date, timeout: TimeInterval,
                    where shouldExpire: (Request) -> Bool = { _ in true }) -> Bool {
        pending.values.contains { shouldExpire($0.request) && date.timeIntervalSince($0.started) > timeout }
    }
}
