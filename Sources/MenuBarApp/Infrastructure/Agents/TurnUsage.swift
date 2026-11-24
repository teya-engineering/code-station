import Foundation

// What one finished turn cost. Read off the CLI's result event, which reports the whole
// turn including every tool call inside it.
struct TurnUsage: Equatable, Sendable {
    var costUSD: Double = 0
    // Plan credits, for an agent that counts in credits rather than dollars (Kiro).
    var credits: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    // What the model is told to use for this model, when it says.
    var contextWindow = 0
    var model: String?
}
