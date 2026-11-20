import Foundation
import Testing
@testable import MenuBarApp

// The spinner words a person set for Claude Code, carried into the app's working row.
// What matters is that they are read from where Claude reads them, settled the way
// Claude settles them, and that nothing set leaves the app's own words alone.
struct ClaudeSpinnerVerbsTests {
    private let scratch = ScratchDirectory(prefix: "spinner-verbs")
    private let words = ["Mulling", "Pondering"]

    private var home: URL { scratch.path("home") }
    private var lead: String { scratch.path("checkout").path }

    private func write(_ text: String, to path: String) throws {
        let url = scratch.path(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func applied(environment: [String: String] = [:]) -> [String] {
        ClaudeSpinnerVerbs.applied(to: words, lead: lead, home: home, environment: environment)
    }

    @Test func leavesTheWordsAloneWhenNothingIsSet() throws {
        #expect(applied() == words)
        try write(#"{"theme": "dark"}"#, to: "home/.claude/settings.json")
        #expect(applied() == words)
    }

    @Test func replaceUsesOnlyThePersonsVerbs() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Box box box", "Sending it into Turn 1"]}}"#,
                  to: "home/.claude/settings.json")
        #expect(applied() == ["Box box box", "Sending it into Turn 1"])
    }

    // Claude adds the verbs to its own when no mode is given, and a verb already in the
    // list is not added twice.
    @Test func appendAddsTheVerbsToTheWordsGiven() throws {
        try write(#"{"spinnerVerbs": {"verbs": ["Pondering", "Lifting and coasting"]}}"#,
                  to: "home/.claude/settings.json")
        #expect(applied() == ["Mulling", "Pondering", "Lifting and coasting"])
    }

    @Test func theNearestFileWins() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Mine"]}}"#,
                  to: "home/.claude/settings.json")
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Shared"]}}"#,
                  to: "checkout/.claude/settings.json")
        #expect(applied() == ["Shared"])

        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Local"]}}"#,
                  to: "checkout/.claude/settings.local.json")
        #expect(applied() == ["Local"])
    }

    @Test func followsAMovedConfigFolder() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Moved"]}}"#,
                  to: "elsewhere/settings.json")
        #expect(applied(environment: ["CLAUDE_CONFIG_DIR": scratch.path("elsewhere").path]) == ["Moved"])
    }

    // An empty or broken setting would leave the row with nothing to say, so the app's
    // words stay instead.
    @Test func keepsTheWordsWhenTheSettingHasNothingToSay() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["  ", ""]}}"#,
                  to: "home/.claude/settings.json")
        #expect(applied() == words)

        try write(#"{"spinnerVerbs": "Pondering"}"#, to: "home/.claude/settings.json")
        #expect(applied() == words)
    }
}
