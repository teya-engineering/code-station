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
            https://github.com/example/conductor/pull/123
            """)
        #expect(found == PullRequest(number: 123, url: "https://github.com/example/conductor/pull/123"))
    }

    // The command fails when there is already a pull request for the branch, and says so
    // with the URL of the one that exists. That is the same answer to the same question.
    @Test func takesTheLinkOutOfTheAlreadyExistsFailure() {
        let found = PullRequestScanner.opened(
            command: #"{"command":"gh pr create --fill"}"#,
            output: "a pull request for branch \"session-4\" into branch \"main\" already exists:\nhttps://github.com/example/conductor/pull/98")
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
                                          output: "https://github.com/example/conductor/pull/5") == nil)
        #expect(PullRequestScanner.opened(command: #"{"command":"git push -u origin HEAD"}"#,
                                          output: "remote: https://github.com/example/conductor/pull/new/session-4") == nil)
    }

    // Trailing punctuation is part of the sentence, not of the link.
    @Test func leavesPunctuationOutOfTheLink() {
        let found = PullRequestScanner.scan("Opened https://github.com/example/conductor/pull/12.")
        #expect(found?.url == "https://github.com/example/conductor/pull/12")
    }

    @Test func findsNothingInOutputWithoutALink() {
        #expect(PullRequestScanner.opened(command: #"{"command":"gh pr create"}"#,
                                          output: "pull request create failed: no commits") == nil)
    }

    // The newest one wins: a session can open more than one, and the last is where the
    // work ended up.
    @Test func picksTheLastPullRequestTheSessionOpened() {
        var session = ChatSession(projectID: UUID())
        session.messages = [
            message(command: "gh pr create --fill", result: "https://github.com/example/conductor/pull/1"),
            message(command: "gh pr view 1", result: "https://github.com/example/conductor/pull/1"),
            message(command: "gh pr create --fill", result: "https://github.com/example/conductor/pull/2")
        ]
        #expect(PullRequestScanner.find(in: session)?.number == 2)
    }

    // A call still in flight has no output to read, and must not be mistaken for one that
    // came back empty.
    @Test func ignoresACallThatHasNotFinished() {
        var session = ChatSession(projectID: UUID())
        session.messages = [message(command: "gh pr create --fill", result: nil)]
        #expect(PullRequestScanner.find(in: session) == nil)
    }

    private func message(command: String, result: String?) -> ChatMessage {
        ChatMessage(role: .assistant,
                    tools: [ToolUse(id: UUID().uuidString,
                                    name: "Bash",
                                    input: #"{"command":"\#(command)"}"#,
                                    result: result)])
    }
}
