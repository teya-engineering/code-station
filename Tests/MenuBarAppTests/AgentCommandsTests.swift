import Foundation
import Testing
@testable import MenuBarApp

// The slash commands offered under the composer, and the words behind them. What is
// checked here is that a name only ever comes from somewhere the agent in question would
// have looked, and that a command the agent cannot expand itself is expanded before it
// is sent rather than arriving as a line it has to guess at.
struct AgentCommandsTests {
    private let scratch = ScratchDirectory(prefix: "agent-commands")

    private func write(_ text: String, to path: String) throws -> URL {
        let url = scratch.path(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aCommandIsOnlyEverTheWholeOfAnUnfinishedPrompt() {
        #expect(SlashQuery.typed(in: "/rev") == "rev")
        #expect(SlashQuery.typed(in: "/") == "")
        #expect(SlashQuery.typed(in: "/code-review") == "code-review")
        // A name that is settled, so the menu has nothing left to offer.
        #expect(SlashQuery.typed(in: "/review ") == nil)
        #expect(SlashQuery.typed(in: "/review the login retry") == nil)
        // A slash inside a sentence is a path or a date far more often than a command.
        #expect(SlashQuery.typed(in: "look at src/main") == nil)
        #expect(SlashQuery.typed(in: "") == nil)
        #expect(SlashQuery.typed(in: "/review\n") == nil)
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

    @Test func aFolderOfFilesBecomesCommands() throws {
        _ = try write("""
        ---
        description: Ship the release notes
        ---
        Write the notes for $ARGUMENTS.
        """, to: "prompts/notes.md")
        _ = try write("# Tidy up\n\nRemove what is not used.\n", to: "prompts/tidy.md")
        _ = try write("Check the API.\n", to: "prompts/review/api.md")
        _ = try write("Nothing here.\n", to: "prompts/skip.txt")

        let found = AgentCommands.onDisk(in: scratch.path("prompts"), scope: .user)

        #expect(found.map(\.name) == ["notes", "review:api", "tidy"])
        #expect(found.map(\.summary) == ["Ship the release notes", "Check the API.", "Tidy up"])
        #expect(found.allSatisfy { $0.scope == .user })
        #expect(found.first?.file?.lastPathComponent == "notes.md")
    }

    @Test func copilotReadsPromptFilesNamedTheWayVSCodeNamesThem() throws {
        _ = try write("Look for flaky tests.\n", to: "project/.github/prompts/flaky.prompt.md")

        let found = AgentCommands.all(for: .copilot,
                                      workingDirectories: [scratch.path("project").path],
                                      home: scratch.path("home"),
                                      environment: [:])

        #expect(found.map(\.name) == ["clear", "flaky"])
        #expect(found.last?.scope == .project)
    }

    @Test func theNearestCopyOfANameWins() throws {
        _ = try write("The project's own.\n", to: "project/.claude/commands/review.md")
        _ = try write("The one you carry everywhere.\n", to: "home/.claude/commands/review.md")
        _ = try write("Only yours.\n", to: "home/.claude/commands/notes.md")

        let found = AgentCommands.all(for: .claudeCode,
                                      workingDirectories: [scratch.path("project").path],
                                      home: scratch.path("home"),
                                      environment: [:])

        // The checkout's own copy, ahead of both the one in the home folder and the CLI's
        // command of the same name.
        #expect(found.filter { $0.name == "review" }.map(\.scope) == [.project])
        #expect(found.first { $0.name == "notes" }?.scope == .user)
        // What the app answers itself is offered whatever the agent is, and the CLI's own
        // commands come last, minus the name a file took.
        #expect(found.map(\.name)
            == ["clear", "compact", "plan", "review", "notes", "init", "security-review"])
    }

    @Test func onlyClaudeIsOfferedTheCommandsOnlyClaudeAnswers() {
        #expect(AgentCommands.builtIns(for: .claudeCode).map(\.name)
            == ["init", "review", "security-review"])
        #expect(AgentCommands.builtIns(for: .codex).isEmpty)
        #expect(AgentCommands.builtIns(for: .copilot).isEmpty)
        #expect(AgentCommands.appCommands(for: .codex).map(\.name) == ["clear"])
        #expect(AgentKind.claudeCode.expandsCommands)
        #expect(!AgentKind.codex.expandsCommands)
        #expect(!AgentKind.copilot.expandsCommands)
    }

    @Test func expandingLeavesTheFrontMatterBehindAndFillsInWhatWasTyped() throws {
        let file = try write("""
        ---
        description: Review a pull request
        model: gpt-5
        ---
        Review $1 and report back on $ARGUMENTS.
        """, to: "prompts/review.md")
        let commands = [AgentCommand(name: "review", summary: "", scope: .user, file: file)]

        #expect(AgentCommands.expansion(of: "/review 42 carefully", in: commands)
            == "Review 42 and report back on 42 carefully.")
        // A placeholder nobody filled in leaves nothing behind.
        #expect(AgentCommands.expansion(of: "/review", in: commands)
            == "Review  and report back on .")
        #expect(AgentCommands.expansion(of: "/REVIEW 42 carefully", in: commands) != nil)
    }

    @Test func aCommandThatAsksForNothingStillGetsWhatWasTyped() throws {
        let file = try write("Run the tests.\n", to: "prompts/tests.md")
        let commands = [AgentCommand(name: "tests", summary: "", scope: .user, file: file)]

        #expect(AgentCommands.expansion(of: "/tests", in: commands) == "Run the tests.")
        #expect(AgentCommands.expansion(of: "/tests only the slow ones", in: commands)
            == "Run the tests.\n\nonly the slow ones")
    }

    @Test func anythingWithoutAFileTravelsAsItWasTyped() {
        let commands = [AgentCommand(name: "init", summary: "", scope: .builtIn),
                        AgentCommand(name: "clear", summary: "", scope: .app)]

        #expect(AgentCommands.expansion(of: "/init", in: commands) == nil)
        #expect(AgentCommands.expansion(of: "/clear", in: commands) == nil)
        #expect(AgentCommands.expansion(of: "/unknown", in: commands) == nil)
        #expect(AgentCommands.expansion(of: "review the login retry", in: commands) == nil)
    }
}

// The prompt an agent that cannot expand a command of its own is actually handed.
@MainActor
struct SlashCommandSendTests {
    @Test func copilotIsSentTheWordsWhileTheTranscriptKeepsTheCommand() async throws {
        let fixture = try RunnerHarness(agent: .copilot, script: """
        printf '%s\\n' "$@" > "$folder/arguments"
        """)
        defer { fixture.tearDown() }
        let prompts = fixture.projectURL.appendingPathComponent(".github/prompts")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        try Data("Run the tests and fix what fails.\n".utf8)
            .write(to: prompts.appendingPathComponent("tests.md"))

        fixture.runner.send("/tests quickly", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: fixture.scratch.path("arguments").path)
        })
        let arguments = try String(contentsOf: fixture.scratch.path("arguments"), encoding: .utf8)
        #expect(arguments.contains("Run the tests and fix what fails.\n\nquickly"))
        #expect(!arguments.contains("/tests quickly"))
        // What was typed is what the conversation shows, not the file behind it.
        #expect(fixture.store.transcript(of: fixture.session.id).first?.text == "/tests quickly")
    }

    // Claude Code reads the prompt off stdin, and expands a command of its own once it
    // arrives, so the line it is handed is the one that was typed.
    @Test func claudeIsSentTheCommandItself() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        head -n 1 > "$folder/input"
        """)
        defer { fixture.tearDown() }
        let commands = fixture.projectURL.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try Data("Run the tests.\n".utf8)
            .write(to: commands.appendingPathComponent("tests.md"))

        fixture.runner.send("/tests", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil(timeout: .seconds(5)) {
            (try? String(contentsOf: fixture.scratch.path("input"), encoding: .utf8))?
                .isEmpty == false
        })
        let line = try String(contentsOf: fixture.scratch.path("input"), encoding: .utf8)
        #expect(line.contains(#""text":"\/tests""#) || line.contains(#""text":"/tests""#))
        #expect(!line.contains("Run the tests."))
    }
}
