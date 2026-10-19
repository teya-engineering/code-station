import Foundation

// The envelope is stable across both servers. Agent-specific payloads stay tolerant
// of extra fields so a CLI update cannot make an unrelated event fail to decode.
public struct AgentRPCMessage {
    public struct Failure {
        public let message: String
    }

    public let id: Any?
    public let method: String?
    public let params: [String: Any]
    public let result: [String: Any]
    public let error: Failure?

    public init(_ object: [String: Any]) {
        id = object["id"]
        method = object["method"] as? String
        params = object["params"] as? [String: Any] ?? [:]
        result = object["result"] as? [String: Any] ?? [:]
        error = (object["error"] as? [String: Any]).map {
            Failure(message: $0["message"] as? String ?? "Unknown protocol error.")
        }
    }
}

public struct AgentRequestTracker<Request> {
    private var nextID = 0
    private var pending: [Int: (request: Request, started: Date)] = [:]

    public var values: [Request] { pending.values.map(\.request) }

    public mutating func insert(_ request: Request, at date: Date) -> Int {
        nextID += 1
        pending[nextID] = (request, date)
        return nextID
    }

    public mutating func remove(_ id: Int) -> Request? {
        pending.removeValue(forKey: id)?.request
    }

    public func hasExpired(at date: Date, timeout: TimeInterval) -> Bool {
        pending.values.contains { date.timeIntervalSince($0.started) > timeout }
    }
}
