import Foundation

// The prompts a session has already sent, newest first, which is the order the up arrow
// walks back through them in.
enum PromptHistory {
    // Only what a person typed at the agent. A command the app sends on their behalf
    // never reaches the transcript as a user message, so what is left to leave out is an
    // empty prompt, which is nothing to go back to, and a prompt sent twice in a row,
    // which would offer the same text at two different depths of the walk.
    static func entries(in transcript: [ChatMessage]) -> [String] {
        var found: [String] = []
        for message in transcript.reversed() where message.role == .user {
            let text = message.text.trimmed
            guard !text.isEmpty, text != found.last else { continue }
            found.append(text)
        }
        return found
    }
}
