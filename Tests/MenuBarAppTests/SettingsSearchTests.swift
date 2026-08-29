import Testing
@testable import MenuBarApp

struct SettingsSearchTests {
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
        #expect(result.tab == .general)
        #expect(result.target == .generalRecaps)
    }
}
