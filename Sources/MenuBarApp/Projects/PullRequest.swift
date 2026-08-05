import Foundation

// The pull request a session opened. Nothing in the stream announces one: the agent opens
// it by running `gh pr create`, which prints the URL of what it made, so that line is the
// only place this can come from.
struct PullRequest: Codable, Equatable, Sendable {
    var number: Int
    var url: String
}

enum PullRequestScanner {
    // Anything ending in /pull/<number>, so a GitHub Enterprise host works the same as
    // github.com. The number is the last thing matched, which keeps trailing punctuation
    // out of the link.
    private static var link: Regex<(Substring, Substring)> { #/https?://[^\s"'<>)\]]+/pull/(\d+)/# }

    // Only the command that opens one counts. A link in a commit message, or a `gh pr
    // view` of somebody else's work, would name a pull request this session did not make.
    private static let opening = "pr create"

    // A command that failed because the pull request already exists still prints its URL,
    // which is the same answer to the same question, so errors are read too.
    static func opened(command: String, output: String) -> PullRequest? {
        guard command.contains(opening) else { return nil }
        return scan(output)
    }

    static func scan(_ text: String) -> PullRequest? {
        guard let match = text.matches(of: link).last, let number = Int(match.1) else { return nil }
        return PullRequest(number: number, url: String(match.0))
    }

    // A session that opened a pull request before the app watched for them still has the
    // line that says so in its transcript. The newest wins: a session can open more than
    // one, and the last is the one the work ended up in.
    static func find(in session: ChatSession) -> PullRequest? {
        for tool in session.messages.flatMap(\.tools).reversed() {
            guard tool.input.contains(opening), let result = tool.result else { continue }
            if let found = scan(result) { return found }
        }
        return nil
    }
}
