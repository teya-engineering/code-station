import Foundation
import Testing
@testable import MenuBarApp

// Spotting the pull request a session opened. The only announcement is the URL the
// command prints, so this is all string work over real `gh` output.
struct PullRequestTests {

    @Test func readsTheLinkGhPrintsWhenItOpensOne() {
        let found = PullRequestScanner.opened(
            command: #"{"command":"gh pr create --title \"Add login page\" --body \"...\""}"#,
            output: """
            Warning: 3 uncommitted changes
            https://github.com/example/code-station/pull/123
            """)
        #expect(found == PullRequest(number: 123, url: "https://github.com/example/code-station/pull/123"))
    }

    // The command fails when there is already a pull request for the branch, and says so
    // with the URL of the one that exists. That is the same answer to the same question.
    @Test func takesTheLinkOutOfTheAlreadyExistsFailure() {
        let found = PullRequestScanner.opened(
            command: #"{"command":"gh pr create --fill"}"#,
            output: "a pull request for branch \"session-4\" into branch \"main\" already exists:\nhttps://github.com/example/code-station/pull/98")
        #expect(found?.number == 98)
    }

    @Test func worksOnAHostThatIsNotGithubCom() {
        let found = PullRequestScanner.opened(command: #"{"command":"gh pr create"}"#,
                                              output: "https://git.example.com/platform/api/pull/7\n")
        #expect(found?.url == "https://git.example.com/platform/api/pull/7")
    }

    // Reading about a pull request is not opening one: the strip says where this
    // session's work went, so only the command that puts it there counts.
    @Test func ignoresCommandsThatOnlyLookAtOne() {
        #expect(PullRequestScanner.opened(command: #"{"command":"gh pr view 5 --json url"}"#,
                                          output: "https://github.com/example/code-station/pull/5") == nil)
        #expect(PullRequestScanner.opened(command: #"{"command":"git push -u origin HEAD"}"#,
                                          output: "remote: https://github.com/example/code-station/pull/new/session-4") == nil)
    }

    // Trailing punctuation is part of the sentence, not of the link.
    @Test func leavesPunctuationOutOfTheLink() {
        let found = PullRequestScanner.scan("Opened https://github.com/example/code-station/pull/12.")
        #expect(found?.url == "https://github.com/example/code-station/pull/12")
    }

    @Test func findsNothingInOutputWithoutALink() {
        #expect(PullRequestScanner.opened(command: #"{"command":"gh pr create"}"#,
                                          output: "pull request create failed: no commits") == nil)
    }

    // A session that works across checkouts opens one in each, and all of them are its
    // work, oldest first.
    @Test func keepsEveryPullRequestTheSessionOpened() {
        var session = ChatSession(projectID: UUID())
        session.messages = [
            message(command: "gh pr create --fill", result: "https://github.com/example/depart-uk/pull/8"),
            message(command: "gh pr view 8", result: "https://github.com/example/depart-uk/pull/8"),
            message(command: "gh pr create --fill", result: "https://github.com/example/depart-uk-ios/pull/3")
        ]
        #expect(PullRequestScanner.find(in: session).map(\.number) == [8, 3])
    }

    // Running the command again for a branch that already has one prints the same link,
    // which is the same pull request rather than a second.
    @Test func listsAPullRequestAnnouncedTwiceOnce() {
        var session = ChatSession(projectID: UUID())
        session.messages = [
            message(command: "gh pr create --fill", result: "https://github.com/example/code-station/pull/1"),
            message(command: "gh pr create --fill",
                    result: "a pull request for branch \"session-4\" already exists:\nhttps://github.com/example/code-station/pull/1")
        ]
        #expect(PullRequestScanner.find(in: session).count == 1)
    }

    // A call still in flight has no output to read, and must not be mistaken for one that
    // came back empty.
    @Test func ignoresACallThatHasNotFinished() {
        var session = ChatSession(projectID: UUID())
        session.messages = [message(command: "gh pr create --fill", result: nil)]
        #expect(PullRequestScanner.find(in: session).isEmpty)
    }

    // What the card names two pull requests by when their numbers do not tell them apart.
    @Test func readsTheRepositoryOutOfTheLink() {
        #expect(PullRequest(number: 8, url: "https://github.com/codfishworks/depart-uk/pull/8")
            .repository == "depart-uk")
        #expect(PullRequest(number: 7, url: "https://git.example.com/gh/platform/api/pull/7")
            .repository == "api")
    }

    private func message(command: String, result: String?) -> ChatMessage {
        ChatMessage(role: .assistant,
                    tools: [ToolUse(id: UUID().uuidString,
                                    name: "Bash",
                                    input: #"{"command":"\#(command)"}"#,
                                    result: result)])
    }
}
