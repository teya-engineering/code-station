import Testing
@testable import MenuBarApp

struct SettingsSearchTests {
    @Test func findsTranscriptTimestamps() throws {
        let result = try #require(SettingsSearchIndex.results(for: "timestamp").first)
        #expect(result.title == "Timestamps")
        #expect(result.target == .appearanceTimestamps)
    }

    @Test func emptySearchHasNoResults() {
        #expect(SettingsSearchIndex.results(for: "   ").isEmpty)
    }

    @Test func searchesRowsAcrossTabs() {
        let results = SettingsSearchIndex.results(for: "session")

        #expect(results.contains { $0.tab == .general && $0.title == "Sessions shown" })
        #expect(results.contains { $0.tab == .appearance && $0.title == "Session text" })
        #expect(results.contains { $0.tab == .agents && $0.title == "Default agent" })
    }

    @Test func everySearchWordMustMatchTheSameRow() throws {
        let result = try #require(SettingsSearchIndex.results(for: "codex toml").first)

        #expect(result.title == "Agent files")
        #expect(result.target == .agentFiles)
    }

    @Test func agentSearchSelectsTheMatchingAgent() throws {
        let result = try #require(SettingsSearchIndex.results(for: "codex account").first)

        #expect(result.tab == .agents)
        #expect(result.target == .agentDetails)
        #expect(result.agent == .codex)
    }

    @Test func findsOrphanedWorktreePruning() throws {
        let result = try #require(SettingsSearchIndex.results(for: "auto prune").first)

        #expect(result.title == "Orphaned worktrees")
        #expect(result.tab == .general)
        #expect(result.target == .generalOrphanedWorktrees)
    }

    @Test func findsAutomaticSessionRecaps() throws {
        let result = try #require(SettingsSearchIndex.results(for: "recap summary").first)

        #expect(result.title == "Automatic session recaps")
        #expect(result.tab == .sessions)
        #expect(result.target == .sessionsRecaps)
    }

    @Test func findsAutomaticSessionTitles() throws {
        let result = try #require(SettingsSearchIndex.results(for: "regenerate title").first)

        #expect(result.title == "Automatic session titles")
        #expect(result.tab == .sessions)
        #expect(result.target == .sessionsTitles)
    }

    @Test func findsTheHeaderButtons() throws {
        let result = try #require(SettingsSearchIndex.results(for: "hide preview").first)

        #expect(result.tab == .appearance)
        #expect(result.target == .appearanceHeaderButtons)
    }

    @Test func findsEnvironmentCredentials() throws {
        let result = try #require(SettingsSearchIndex.results(for: "environment credentials").first)

        #expect(result.title == "Current configuration")
        #expect(result.tab == .advanced)
        #expect(result.target == .advancedConfiguration)
    }

    @Test func sessionBehaviourLivesInTheSessionsTab() {
        let titles = SettingsSearchIndex.entries.filter { $0.tab == .sessions }.map(\.title)
        #expect(titles == ["Prompts sent during a turn", "Automatic session recaps",
                           "Automatic session titles", "Suggest the next prompt",
                           "Session finished sound", "Session memory"])
    }

    @Test func findsTheSessionLogInAdvanced() throws {
        let result = try #require(SettingsSearchIndex.results(for: "session log").first)

        #expect(result.title == "Session log")
        #expect(result.tab == .advanced)
        #expect(result.target == .advancedSessionLog)
    }

    // Every target belongs to exactly one tab, so a link to it always opens the right one.
    @Test func eachTargetSitsInOneTab() {
        let tabsByTarget = Dictionary(grouping: SettingsSearchIndex.entries, by: \.target)
            .mapValues { Set($0.map(\.tab)) }
        #expect(tabsByTarget.values.allSatisfy { $0.count == 1 })
    }
}
