import Foundation

// Why the façade turned a command down, in words a front end can show as they are. It is
// a plain value, like everything else the façade hands out, so a socket can carry it as
// the phone is carried an error.
public struct StationRefusal: Error, Codable, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    static let noSession = StationRefusal("That session is no longer available.")
    static let emptyPrompt = StationRefusal("Write a prompt first.")
    static let longPrompt = StationRefusal("That prompt is too long.")
    static let noProject = StationRefusal("That project is no longer available.")
    static let noQuestion = StationRefusal("That question is no longer waiting for an answer.")
    static let invalidAnswer = StationRefusal("That answer is not valid for this question.")
    static let unansweredQuestion = StationRefusal("Answer every question first.")
}

// Which way a recall steps through the prompts a session has sent: back to older ones,
// or forward to newer ones and, past the newest, an empty composer.
public enum PromptRecall: String, Codable, Equatable, Sendable {
    case earlier, later
}
