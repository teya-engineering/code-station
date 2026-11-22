import Foundation

// Something an agent's CLI or server could not do, in words fit to show as they are.
struct AgentFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
