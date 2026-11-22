import Foundation
import Testing
@testable import MenuBarApp

// The spinner words a person set for Claude Code, carried into the app's working row.
// What matters is that they are read from where Claude reads them, settled the way
// Claude settles them, and that nothing set leaves the app's own words alone.
struct ClaudeSpinnerVerbsTests {
    private let scratch = ScratchDirectory(prefix: "spinner-verbs")
    private let words = ["Mulling", "Pondering"]

    private var config: URL { scratch.path("config") }
    private var lead: String { scratch.path("checkout").path }

    private func write(_ text: String, to path: String) throws {
        let url = scratch.path(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func applied() -> [String] {
        ClaudeSpinnerVerbs.load(configDirectory: config, lead: lead)?.applied(to: words) ?? words
    }

    @Test func leavesTheWordsAloneWhenNothingIsSet() throws {
        #expect(ClaudeSpinnerVerbs.load(configDirectory: config, lead: lead) == nil)
        try write(#"{"theme": "dark"}"#, to: "config/settings.json")
        #expect(ClaudeSpinnerVerbs.load(configDirectory: config, lead: lead) == nil)
    }

    @Test func replaceUsesOnlyThePersonsVerbs() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Box box box", "Sending it into Turn 1"]}}"#,
                  to: "config/settings.json")
        #expect(applied() == ["Box box box", "Sending it into Turn 1"])
    }

    @Test func appendAddsTheVerbsToTheWordsGiven() throws {
        try write(#"{"spinnerVerbs": {"mode": "append", "verbs": ["Pondering", "Lifting and coasting"]}}"#,
                  to: "config/settings.json")
        #expect(applied() == ["Mulling", "Pondering", "Lifting and coasting"])
    }

    // Claude merges its settings files rather than picking one: the nearest mode wins and
    // the lists are joined, so a checkout that only adds a verb still replaces the words
    // when the person's own file says to.
    @Test func theFilesAreMergedTheWayClaudeMergesThem() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Mine", "Shared"]}}"#,
                  to: "config/settings.json")
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Shared", "Project"]}}"#,
                  to: "checkout/.claude/settings.json")
        try write(#"{"spinnerVerbs": {"mode": "append", "verbs": ["Local"]}}"#,
                  to: "checkout/.claude/settings.local.json")

        #expect(ClaudeSpinnerVerbs.load(configDirectory: config, lead: lead)
                == ClaudeSpinnerVerbs(mode: .append, verbs: ["Mine", "Shared", "Project", "Local"]))
    }

    // Claude rejects a setting with no mode, or with something other than a list of
    // words, and skips that file. The files below it still count.
    @Test func aFileClaudeRejectsIsSkipped() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Mine"]}}"#, to: "config/settings.json")
        for broken in [#"{"spinnerVerbs": {"verbs": ["Box"]}}"#,
                       #"{"spinnerVerbs": {"mode": "replace", "verbs": "Box"}}"#,
                       #"{"spinnerVerbs": {"mode": "shuffle", "verbs": ["Box"]}}"#,
                       #"{"spinnerVerbs": {"mode": "replace", "verbs": ["Box"]"#] {
            try write(broken, to: "checkout/.claude/settings.local.json")
            #expect(applied() == ["Mine"])
        }
    }

    // A replace with nothing usable in it would leave the row with nothing to say, so the
    // app's words stay instead, as Claude's own do.
    @Test func keepsTheWordsWhenTheSettingHasNothingToSay() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["  ", ""]}}"#,
                  to: "config/settings.json")
        #expect(applied() == words)
    }

    @Test func readsOnlyTheConfigFolderWithoutACheckout() throws {
        try write(#"{"spinnerVerbs": {"mode": "replace", "verbs": ["Mine"]}}"#, to: "config/settings.json")
        #expect(ClaudeSpinnerVerbs.load(configDirectory: config, lead: nil)?.verbs == ["Mine"])
    }
}
