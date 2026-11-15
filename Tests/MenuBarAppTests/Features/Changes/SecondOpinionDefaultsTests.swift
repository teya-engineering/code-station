import Foundation
import Testing
@testable import MenuBarApp

// What an ask for a second opinion starts from, and what a reviewer can reach when the
// person lets it use their MCP servers.
struct SecondOpinionDefaultsTests {
    private let codex = SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol", effort: "high")
    private let copilot = SecondOpinion.Reviewer(agent: .copilot, model: "claude-sonnet-5")
    private let claude = SecondOpinion.Reviewer(agent: .claudeCode, model: "opus")

    private func store() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "second-opinion-\(UUID().uuidString)"))
    }

    @Test func freshDefaultsKeepTodaysAsk() {
        let defaults = SecondOpinionDefaults()
        #expect(defaults.lineup.isEmpty)
        #expect(defaults.chatFocus == Set(ChatSecondOpinion.Focus.standard))
        #expect(defaults.changesFocus == Set(SecondOpinion.Focus.standard))
        #expect(defaults.designFocus == Set(DesignSecondOpinion.Focus.standard))
        #expect(defaults.chatReading == ChatSecondOpinion.Reading())
        #expect(defaults.designReading == DesignSecondOpinion.Reading())
        #expect(!defaults.usesServers)
    }

    @Test func anUntickedSeatIsLeftOutButKeepsItsModelAndEffort() throws {
        let store = try store()
        Preferences.setSecondOpinionLineup([codex, copilot], in: store)
        var defaults = Preferences.secondOpinionDefaults(in: store)
        defaults.seats[0].on = false
        Preferences.setSecondOpinionDefaults(defaults, in: store)

        #expect(Preferences.secondOpinionLineup(in: store) == [copilot])
        let kept = Preferences.secondOpinionDefaults(in: store).seats[0]
        #expect(kept == .init(reviewer: codex, on: false))
    }

    @Test func makingALineupUsualKeepsTheOtherSeatsUnticked() {
        var defaults = SecondOpinionDefaults(seats: [.init(reviewer: codex), .init(reviewer: copilot)])
        defaults.makeUsual([claude, claude])
        #expect(defaults.seats == [.init(reviewer: claude), .init(reviewer: codex, on: false),
                                   .init(reviewer: copilot, on: false)])
        #expect(defaults.lineup == [claude])
    }

    @Test func makingALineupUsualStaysWithinTheSeatLimit() {
        let extra = (0..<4).map { SecondOpinion.Reviewer(agent: .codex, model: "model-\($0)") }
        var defaults = SecondOpinionDefaults(seats: extra.map { .init(reviewer: $0) })
        defaults.makeUsual([claude, copilot])
        #expect(defaults.seats.count == SecondOpinion.Reviewer.maxSeats)
        #expect(defaults.lineup == [claude, copilot])
    }

    @Test func aLineupSavedBeforeSettingsBecomesTheUsualSeats() throws {
        let store = try store()
        store.set(try JSONEncoder().encode([codex, copilot]), forKey: "secondOpinionLineup")
        let defaults = Preferences.secondOpinionDefaults(in: store)
        #expect(defaults.seats == [.init(reviewer: codex), .init(reviewer: copilot)])
        #expect(!defaults.usesServers)
    }

    @Test func everySettingSurvivesBeingSaved() throws {
        let store = try store()
        var defaults = SecondOpinionDefaults(seats: [.init(reviewer: codex, on: false), .init(reviewer: claude)])
        defaults.chatFocus = [.simplerWay]
        defaults.changesFocus = [.missingTests, .bugs]
        defaults.designFocus = [.copy]
        defaults.chatReading = .init(files: false, conversation: true)
        defaults.designReading = .init(source: false, conversation: true)
        defaults.usesServers = true
        Preferences.setSecondOpinionDefaults(defaults, in: store)
        #expect(Preferences.secondOpinionDefaults(in: store) == defaults)
    }

    @Test func aFocusTheAppNoLongerKnowsDoesNotLoseTheRest() throws {
        let json = #"{"seats":[],"chatFocus":["risks","gone"],"changesFocus":["gone"],"usesServers":true}"#
        let defaults = try JSONDecoder().decode(SecondOpinionDefaults.self, from: Data(json.utf8))
        #expect(defaults.chatFocus == [.risks])
        #expect(defaults.changesFocus == Set(SecondOpinion.Focus.standard))
        #expect(defaults.usesServers)
    }

    @Test func theLastThingToLookForCannotBeTurnedOff() {
        #expect(SecondOpinionDefaults.toggled(SecondOpinion.Focus.bugs, in: [.bugs]) == nil)
        #expect(SecondOpinionDefaults.toggled(SecondOpinion.Focus.bugs, in: [.bugs, .security]) == [.security])
        #expect(SecondOpinionDefaults.toggled(SecondOpinion.Focus.bugs, in: [.security]) == [.bugs, .security])
    }

    @Test func aSecondSeatTakesAModelNoSeatOfItsAgentUses() {
        var defaults = SecondOpinionDefaults(seats: [.init(reviewer: SecondOpinion.Reviewer(agent: .codex))])
        defaults.addSeat(.codex, models: [nil, "gpt-5.6-sol", "gpt-5.4"], effort: nil)
        #expect(defaults.seats.last?.reviewer == SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol"))
        #expect(defaults.isExtraSeat(at: 1))
        #expect(!defaults.isExtraSeat(at: 0))
        defaults.addSeat(.codex, models: [nil, "gpt-5.6-sol", "gpt-5.4"], effort: nil)
        defaults.addSeat(.codex, models: [nil, "gpt-5.6-sol", "gpt-5.4"], effort: nil)
        defaults.addSeat(.codex, models: [nil, "gpt-5.6-sol", "gpt-5.4"], effort: nil)
        #expect(defaults.seats.count == SecondOpinion.Reviewer.maxSeats)
    }

    // MARK: MCP servers

    @Test func withoutServerAccessEveryReviewerRunsWithoutMCP() throws {
        let claude = SecondOpinion.arguments(for: .claudeCode, prompt: "p")
        #expect(claude.contains("--strict-mcp-config"))
        let allowed = try #require(claude.firstIndex(of: "--allowedTools"))
        #expect(claude[allowed + 1] == "Read,Grep,Glob")
        #expect(SecondOpinion.arguments(for: .copilot, prompt: "p").contains("--disable-builtin-mcps"))
    }

    @Test func claudeIsAllowedTheSessionsServersAndStillCannotWrite() throws {
        let access = SecondOpinion.ServerAccess(claudeServers: ["grafana", "glean"])
        let arguments = SecondOpinion.arguments(for: SecondOpinion.Reviewer(agent: .claudeCode), prompt: "p", servers: access)
        #expect(!arguments.contains("--strict-mcp-config"))
        let allowed = try #require(arguments.firstIndex(of: "--allowedTools"))
        #expect(arguments[allowed + 1] == "Read,Grep,Glob,mcp__grafana,mcp__glean")
        let disallowed = try #require(arguments.firstIndex(of: "--disallowedTools"))
        #expect(arguments[disallowed + 1] == "Edit,Write,MultiEdit,NotebookEdit,Bash")
    }

    @Test func copilotUsesItsServersButNotTheOnesTheSessionKeepsOff() {
        let access = SecondOpinion.ServerAccess(disabled: [DisabledMCPServer(name: "browser", transport: .stdio)])
        let arguments = SecondOpinion.arguments(for: SecondOpinion.Reviewer(agent: .copilot), prompt: "p", copilotServers: ["browser", "files"],
                                                servers: access)
        #expect(!arguments.contains("--disable-builtin-mcps"))
        #expect(arguments.contains("--allow-tool=files"))
        #expect(arguments.contains("--deny-tool=browser"))
        #expect(!arguments.contains("--allow-tool=browser"))
        #expect(arguments.contains("--deny-tool=shell"))
        #expect(arguments.contains("--deny-tool=write"))
    }

    @Test func codexTurnsOffOnlyWhatTheSessionKeepsOff() {
        let arguments = SecondOpinion.arguments(for: SecondOpinion.Reviewer(agent: .codex), prompt: "p",
                                                codexServers: [DisabledMCPServer(name: "browser", transport: .stdio)],
                                                servers: .init())
        #expect(arguments.contains(#"mcp_servers={"browser"={enabled=false,command="/usr/bin/false"}}"#))
        #expect(arguments.contains("read-only"))
    }

    @Test func aSessionWithoutMCPKeepsItsReviewersWithoutIt() {
        #expect(SecondOpinion.ServerAccess.session(SessionSettings(mcpServersEnabled: false),
                                                   claudeServers: ["files"]) == nil)
        let held = SecondOpinion.ServerAccess.session(SessionSettings(allowedMCPServerNames: ["grafana"]),
                                                      claudeServers: ["files", "grafana"])
        #expect(held?.claudeServers == ["grafana"])
        #expect(SecondOpinion.ServerAccess.session(nil, claudeServers: ["files"])?.claudeServers == ["files"])
    }

    @Test func claudesServersAreReadFromItsOwnConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mcpServers": {"grafana": {"command": "g"}, "glean": {"url": "https://x"}}}"#.utf8).write(to: url)
        #expect(SecondOpinion.claudeServers(in: url) == ["glean", "grafana"])
        #expect(SecondOpinion.claudeServers(in: url.appendingPathExtension("missing")).isEmpty)
    }

    @Test func theSafetyLineSaysWhenAToolCanAct() {
        for kind in [SecondOpinionStop.Kind.chat, .changes, .design] {
            #expect(SecondOpinionAsk.safety(kind, usesServers: false, author: .codex).contains("MCP servers"))
            #expect(SecondOpinionAsk.safety(kind, usesServers: true, author: .codex).contains("a tool there can act"))
        }
        #expect(SecondOpinionAsk.safety(.chat, usesServers: true, author: .codex)
            == "They can read files but not change them. Your MCP servers are open to them, and a tool there can act. Codex sees nothing they say until you send it.")
    }

    @Test func settingsSearchFindsTheMCPSwitch() throws {
        let result = try #require(SettingsSearchIndex.results(for: "reviewer mcp").first)
        #expect(result.tab == .secondOpinion)
        #expect(result.target == .secondOpinionAccess)
    }
}
