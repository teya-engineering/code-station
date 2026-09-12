import Foundation

// A pull request a session opened. Nothing in the stream announces one: the agent opens
// it by running `gh pr create`, which prints the URL of what it made, so that line is the
// only place this can come from.
struct PullRequest: Codable, Equatable, Sendable {
    var number: Int
    var url: String

    // The repository the pull request is in, which is what tells two of them apart when a
    // session works across checkouts and both land on the same number. It is the path
    // segment before `/pull/<number>`, read from the end so a host with a prefix in front
    // of the owner still gives the same answer.
    var repository: String? {
        let parts = url.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        return String(parts[parts.count - 3])
    }
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

    // A session that opened pull requests before the app watched for them still has the
    // lines that say so in its transcript. One session can open several - one per
    // checkout of a workspace, or one per round of work - and they are all its work, so
    // they are all kept, in the order they were opened.
    static func find(in session: ChatSession) -> [PullRequest] {
        var found: [PullRequest] = []
        for tool in session.messages.flatMap(\.tools) {
            guard tool.input.contains(opening), let result = tool.result else { continue }
            guard let pullRequest = scan(result) else { continue }
            found.append(pullRequest)
        }
        return found.deduplicatedByURL()
    }
}

extension [PullRequest] {
    // The same pull request announces itself again every time the agent retries the
    // command that opened it, or runs it once more for a branch that already has one.
    func deduplicatedByURL() -> [PullRequest] {
        var seen: Set<String> = []
        return filter { seen.insert($0.url).inserted }
    }
}
