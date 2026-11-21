import Foundation
import Testing
@testable import MenuBarApp

// The slash words the composer finds in a prompt, and what its menu offers for them.
struct SlashQueryTests {
    private static func length(_ text: String) -> Int { (text as NSString).length }

    @Test func theMenuFollowsTheSlashWordTheCaretIsIn() {
        #expect(SlashQuery.word(in: "/rev", caret: 4)?.query == "rev")
        #expect(SlashQuery.word(in: "/", caret: 1)?.query == "")
        #expect(SlashQuery.word(in: "/code-review", caret: 12)?.query == "code-review")
        // Only what is typed up to the caret counts.
        #expect(SlashQuery.word(in: "/review", caret: 4)?.query == "rev")

        let prompt = "/validate-pr-comments and then /add"
        let later = SlashQuery.word(in: prompt, caret: Self.length(prompt))
        #expect(later?.query == "add")
        #expect(later?.atStart == false)
        #expect(later?.range == NSRange(location: 31, length: 4))
        #expect(SlashQuery.word(in: prompt, caret: 5)?.atStart == true)

        // Past the word, before the slash, in plain words, or with a selection, there is
        // no word and so no menu.
        #expect(SlashQuery.word(in: "/review ", caret: 8) == nil)
        #expect(SlashQuery.word(in: "/review the login retry", caret: 23) == nil)
        #expect(SlashQuery.word(in: "then /add", caret: 5) == nil)
        #expect(SlashQuery.word(in: "/rev", caret: nil) == nil)
        #expect(SlashQuery.word(in: "", caret: 0) == nil)
        #expect(SlashQuery.word(in: "/review\n", caret: 8) == nil)
    }

    @Test(arguments: ["/Users/x/projects", "look at src/routes", "on 11/20", "and/or",
                      "(/review-pr)", "`/review`"])
    func aSlashInsideAWordOrAPathIsNeverACommand(prompt: String) {
        #expect(SlashQuery.words(in: prompt).isEmpty)
        #expect(SlashQuery.word(in: prompt, caret: Self.length(prompt)) == nil)
    }

    @Test func aLeadingNameRunsToTheSpaceAndALaterOneStopsAtPunctuation() throws {
        let words = SlashQuery.words(in: "/review. then /address-pr-comments. and /plugin:skill: done")
        #expect(words.map(\.name) == ["review.", "address-pr-comments", "plugin:skill"])
        #expect(words.map(\.atStart) == [true, false, false])
        let later = try #require(words.dropFirst().first)
        #expect(later.nameRange.length == "/address-pr-comments".count)
        #expect(later.range.length == "/address-pr-comments.".count)

        // A slash after a tab or a new line counts too, and leading space is still the start.
        #expect(SlashQuery.words(in: "  /clear").map(\.atStart) == [true])
        #expect(SlashQuery.words(in: "fix it\n/review\tand\t/tidy").map(\.name) == ["review", "tidy"])
        // Text that comes later in a prompt has nothing at its start.
        #expect(SlashQuery.words(in: "/review.", opensPrompt: false).map(\.name) == ["review"])
    }

    @Test func aSlashWordInCodeIsNeverACommand() {
        #expect(SlashQuery.words(in: "run `x /address-pr-comments` now").isEmpty)
        #expect(SlashQuery.words(in: "run ``a ` /address-pr-comments`` now").isEmpty)
        let fenced = "see:\n```\n/address-pr-comments\n```\nthen /review"
        #expect(SlashQuery.words(in: fenced).map(\.name) == ["review"])
        #expect(SlashQuery.words(in: "~~~\n/address-pr-comments").isEmpty)
        // Until the closing backtick is typed the span is not code yet.
        #expect(SlashQuery.word(in: "run `x /add", caret: 11) != nil)
        #expect(SlashQuery.word(in: "run `x /add`", caret: 11) == nil)
        // A backtick with nothing to close it is only a backtick.
        #expect(SlashQuery.words(in: "it's a ` then /address-pr-comments").map(\.name)
            == ["address-pr-comments"])
        // Code before the first command still counts as words before it.
        #expect(SlashQuery.words(in: "```\nx\n```\n/clear").map(\.atStart) == [false])
    }

    private let names = SlashCommandNames(
        leading: ["clear", "review", "validate-pr-comments", "address-pr-comments", "humanizer:humanizer"],
        inline: ["validate-pr-comments", "address-pr-comments", "humanizer:humanizer"])

    private func coloured(_ text: String, caret: Int? = nil, opensPrompt: Bool = true) -> [String] {
        SlashQuery.highlightedRanges(in: text, caret: caret, names: names, opensPrompt: opensPrompt)
            .map { (text as NSString).substring(with: $0) }
    }

    @Test func everyRecognisedCommandIsColouredWhereItSits() {
        #expect(coloured("/validate-pr-comments and then /address-pr-comments")
            == ["/validate-pr-comments", "/address-pr-comments"])
        #expect(coloured("/validate-pr-comments and then /address-pr-comments.")
            == ["/validate-pr-comments", "/address-pr-comments"])
        // The word being typed is coloured while a command offered there starts with it.
        #expect(coloured("/validate-pr-comments and then /add", caret: 35)
            == ["/validate-pr-comments", "/add"])
        #expect(coloured("/validate-pr-comments and then /add") == ["/validate-pr-comments"])
        // A typo, or a command that only works first, stays plain later in the prompt.
        #expect(coloured("/review then /humanizr:humanizer the replies") == ["/review"])
        #expect(coloured("Summarise it, then /clear") == [])
        #expect(coloured("Summarise it, then /cl", caret: 22) == [])
        #expect(coloured("/review.", opensPrompt: false) == [])
        #expect(coloured("/address-pr-comments.", opensPrompt: false) == ["/address-pr-comments"])
        #expect(coloured("/review `then /address-pr-comments`") == ["/review"])
    }

    @Test func laterInAPromptOnlyCommandsThatStillRunAreOffered() {
        let commands = [AgentCommand(name: "clear", summary: "", scope: .app),
                        AgentCommand(name: "cleanup-worktree", summary: "", scope: .user),
                        AgentCommand(name: "review", summary: "", scope: .builtIn),
                        AgentCommand(name: "run-e2e", summary: "", scope: .project),
                        AgentCommand(name: "superpowers:brainstorming", summary: "", scope: .plugin)]
        let start = SlashQuery.word(in: "/cl", caret: 3)!
        let later = SlashQuery.word(in: "Summarise it, then /cl", caret: 22)!

        #expect(SlashQuery.offer(for: start, in: commands, agent: .claudeCode).usable.map(\.name)
            == ["clear", "cleanup-worktree"])
        let offer = SlashQuery.offer(for: later, in: commands, agent: .claudeCode)
        #expect(offer.usable.map(\.name) == ["cleanup-worktree"])
        #expect(offer.startOnly.map(\.name) == ["clear"])

        // A slash on its own is the whole list at the start, and just a slash later on.
        #expect(SlashQuery.offer(for: SlashQuery.word(in: "/", caret: 1)!, in: commands,
                                 agent: .claudeCode).usable.count == commands.count)
        #expect(SlashQuery.offer(for: SlashQuery.word(in: "A / B", caret: 3)!, in: commands,
                                 agent: .claudeCode).isEmpty)

        // The app expands only a leading command for Codex and Copilot, so nothing later
        // in their prompts would run.
        let codex = SlashQuery.offer(for: later, in: commands, agent: .codex)
        #expect(codex.usable.isEmpty)
        #expect(codex.startOnly.map(\.name) == ["clear", "cleanup-worktree"])
        #expect(SlashCommandNames(commands, agent: .codex).inline.isEmpty)
        #expect(SlashCommandNames(commands, agent: .claudeCode).inline
            == ["cleanup-worktree", "run-e2e", "superpowers:brainstorming"])
    }

    @Test func pickingACommandReplacesOnlyTheWordAtTheCaret() throws {
        let command = AgentCommand(name: "address-pr-comments", summary: "", scope: .user)
        func complete(_ text: String, caret: Int) throws -> (text: String, caret: Int) {
            let word = try #require(SlashQuery.word(in: text, caret: caret))
            return SlashQuery.completing(word, with: command, caret: caret, in: text)
        }

        let end = try complete("/validate-pr-comments and then /add", caret: 35)
        #expect(end.text == "/validate-pr-comments and then /address-pr-comments ")
        #expect(end.caret == Self.length(end.text))

        // A space already there is kept, and the caret goes past it.
        let middle = try complete("then /add and reply", caret: 9)
        #expect(middle.text == "then /address-pr-comments and reply")
        #expect(middle.caret == 26)

        // Punctuation after the name stays, and the caret stops before it.
        let comma = try complete("then /add, and reply", caret: 9)
        #expect(comma.text == "then /address-pr-comments, and reply")
        #expect(comma.caret == 25)

        // The caret part way through a name replaces the whole of it.
        let inside = try complete("then /addr-pr and reply", caret: 9)
        #expect(inside.text == "then /address-pr-comments and reply")

        // A line break is left where it is, with the caret before it.
        let line = try complete("then /add\nmore", caret: 9)
        #expect(line.text == "then /address-pr-comments\nmore")
        #expect(line.caret == 25)
    }

    @Test func matchesPutTheNearestNameFirst() {
        let commands = ["reviewers", "review", "security-review", "backend:review", "rebase"]
            .map { AgentCommand(name: $0, summary: "", scope: .user) }

        #expect(SlashQuery.matches("review", in: commands).map(\.name)
            == ["review", "reviewers", "backend:review", "security-review"])
        #expect(SlashQuery.matches("re", in: commands).map(\.name)
            == ["reviewers", "review", "rebase", "backend:review", "security-review"])
        #expect(SlashQuery.matches("RE", in: commands).map(\.name).first == "reviewers")
        #expect(SlashQuery.matches("zzz", in: commands).isEmpty)
        // Nothing typed yet is everything, in the order it was gathered.
        #expect(SlashQuery.matches("", in: commands).map(\.name) == commands.map(\.name))
    }
}
