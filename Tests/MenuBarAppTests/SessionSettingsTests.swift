import Foundation
import Testing
@testable import MenuBarApp

// What a session runs with, and what it reads back off the CLI about the cost. The
// payloads here are real ones taken off the wire.
struct SessionSettingsTests {

    @MainActor
    @Test func newSessionsOnlyOfferInstalledAgents() {
        let runner = SessionRunner(paths: [
            .claudeCode: "/usr/local/bin/claude",
            .codex: "/usr/local/bin/codex",
        ])

        #expect(runner.availableAgents == [.claudeCode, .codex])
        #expect(runner.agentForNewSession(selected: nil) == runner.agent)
        #expect(runner.agentForNewSession(selected: .codex) == .codex)
    }

    @MainActor
    @Test func newSessionsUseTheOnlyInstalledAgent() {
        let runner = SessionRunner(paths: [.codex: "/usr/local/bin/codex"])

        #expect(runner.availableAgents == [.codex])
        #expect(runner.agentForNewSession(selected: nil) == .codex)
        #expect(runner.agentForNewSession(selected: .claudeCode) == .codex)
    }

    @MainActor
    @Test func newSessionsNeedAnInstalledAgent() {
        let runner = SessionRunner(paths: [:])

        #expect(runner.availableAgents.isEmpty)
        #expect(runner.agentForNewSession(selected: nil) == nil)
    }

    @MainActor
    @Test func updatesAnAgentsDefaultsWithoutChangingTheDefaultAgent() {
        let savedAgent = Preferences.agent
        let savedClaudeDefaults = Preferences.sessionDefaults(for: .claudeCode)
        let savedCodexDefaults = Preferences.sessionDefaults(for: .codex)
        defer {
            Preferences.agent = savedAgent
            Preferences.setSessionDefaults(savedClaudeDefaults, for: .claudeCode)
            Preferences.setSessionDefaults(savedCodexDefaults, for: .codex)
        }

        let runner = SessionRunner(paths: [:])
        runner.agent = .claudeCode
        let claudeDefaults = runner.defaults(for: .claudeCode)
        let codexDefaults = SessionSettings(model: "gpt-5.6-sol",
                                            effort: "high",
                                            codexSandboxMode: "workspace-write")

        runner.setDefaults(codexDefaults, for: .codex)

        #expect(runner.agent == .claudeCode)
        #expect(runner.defaults(for: .claudeCode) == claudeDefaults)
        #expect(runner.defaults(for: .codex) == codexDefaults)
    }

    // MARK: - Arguments

    private let appDefaults = SessionSettings(permissionMode: "acceptEdits")

    @Test func leavesUnsetChoicesOffTheCommandLine() {
        let arguments = SessionRunner.arguments(settings: SessionSettings(), defaults: appDefaults)
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--effort"))
        #expect(!arguments.contains("--add-dir"))
        #expect(!arguments.contains("--resume"))
        #expect(!arguments.contains("--fork-session"))
        // The mode is always sent, since the app has one whether or not the session does.
        #expect(arguments.contains("--permission-mode"))
        #expect(arguments.contains("acceptEdits"))
    }

    @Test func sendsWhatTheSessionChose() {
        let settings = SessionSettings(model: "opus", effort: "high", permissionMode: "manual")
        let arguments = SessionRunner.arguments(settings: settings,
                                                defaults: appDefaults,
                                                addDirectories: ["/tmp/shots"],
                                                resume: "abc-123")
        #expect(pair(arguments, after: "--model") == "opus")
        #expect(pair(arguments, after: "--effort") == "high")
        #expect(pair(arguments, after: "--permission-mode") == "manual")
        #expect(pair(arguments, after: "--add-dir") == "/tmp/shots")
        #expect(pair(arguments, after: "--resume") == "abc-123")
        // Resuming always forks: the old id stays frozen as the checkpoint a rewind
        // resumes from.
        #expect(arguments.contains("--fork-session"))
    }

    // The model belongs to the session, while other controls can still follow app
    // defaults between turns.
    @Test func doesNotInheritTheAppDefaultModel() {
        let defaults = SessionSettings(model: "sonnet", effort: "low", permissionMode: "auto")
        let arguments = SessionRunner.arguments(settings: SessionSettings(), defaults: defaults)
        #expect(!arguments.contains("--model"))
        #expect(pair(arguments, after: "--effort") == "low")
        #expect(pair(arguments, after: "--permission-mode") == "auto")
    }

    @Test func theSessionWinsOverTheAppDefault() {
        let defaults = SessionSettings(model: "sonnet", effort: "low", permissionMode: "auto")
        let arguments = SessionRunner.arguments(settings: SessionSettings(model: "haiku"),
                                                defaults: defaults)
        #expect(pair(arguments, after: "--model") == "haiku")
        // Only the model was overridden, so the rest still comes from the app.
        #expect(pair(arguments, after: "--effort") == "low")
        #expect(pair(arguments, after: "--permission-mode") == "auto")
    }

    @Test func emptyChoicesAreTreatedAsUnset() {
        let arguments = SessionRunner.arguments(settings: SessionSettings(model: "", effort: ""),
                                                defaults: SessionSettings(permissionMode: "auto"),
                                                resume: "")
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--effort"))
        #expect(!arguments.contains("--resume"))
        #expect(!arguments.contains("--fork-session"))
    }

    // Nothing chosen anywhere still has to name a mode: the app is what shows the
    // questions, so it never leaves that to the CLI's own configuration.
    @Test func alwaysNamesAPermissionMode() {
        let arguments = SessionRunner.arguments(settings: SessionSettings(),
                                                defaults: SessionSettings())
        #expect(pair(arguments, after: "--permission-mode") == "acceptEdits")
    }

    // The app draws the choices itself, so every Claude session is asked to reach for the
    // tool that puts them on screen. Codex has no such tool and would refuse the flag.
    @Test func asksClaudeToUseTheModalChooser() {
        let claude = SessionRunner.arguments(settings: SessionSettings(), defaults: appDefaults)
        #expect(pair(claude, after: "--append-system-prompt")
            == SessionRunner.appendedSystemPrompt)

        let codex = SessionRunner.arguments(agent: .codex,
                                            settings: SessionSettings(),
                                            defaults: appDefaults)
        #expect(!codex.contains("--append-system-prompt"))
    }

    private func pair(_ arguments: [String], after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    // MARK: - Naming the model that ran

    @Test func shortensTheModelNameTheCLIReports() {
        #expect(ModelChoice.shortName(of: "claude-opus-5") == "Opus 5")
        #expect(ModelChoice.shortName(of: "claude-sonnet-5") == "Sonnet 5")
        #expect(ModelChoice.shortName(of: "claude-haiku-4-5") == "Haiku 4.5")
        // A dated build and a window variant are both noise on a strip this small.
        #expect(ModelChoice.shortName(of: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelChoice.shortName(of: "claude-opus-5[1m]") == "Opus 5")
    }

    // Model names change without the app being told, so anything unrecognised has to come
    // out readable rather than empty.
    @Test func leavesAnUnfamiliarModelNameAlone() {
        #expect(ModelChoice.shortName(of: "opus") == "Opus")
        #expect(ModelChoice.shortName(of: "some-future-thing") == "Some future.thing")
        #expect(ModelChoice.shortName(of: "") == "")
    }

    // MARK: - Reading usage off the stream

    private let result = """
    {"is_error":false,"duration_api_ms":3516,"num_turns":1,"session_id":"c716258a",\
    "total_cost_usd":0.1443,"usage":{"input_tokens":2,"cache_creation_input_tokens":13628,\
    "cache_read_input_tokens":15410,"output_tokens":13,"service_tier":"standard"},\
    "modelUsage":{"claude-opus-5[1m]":{"inputTokens":2,"outputTokens":13,"cacheReadInputTokens":15410,\
    "cacheCreationInputTokens":13628,"costUSD":0.1443,"contextWindow":1000000,\
    "canonicalModel":"claude-opus-5","provider":"firstParty"}},"subtype":"success",\
    "result":"Hi!","type":"result"}
    """

    @Test func readsTheCostAndTokensOfAFinishedTurn() throws {
        let events = StreamEvent.parse(result)
        guard case .usage(let usage)? = events.first else {
            Issue.record("expected usage first, got \(events)")
            return
        }
        #expect(usage.costUSD == 0.1443)
        #expect(usage.inputTokens == 2)
        #expect(usage.outputTokens == 13)
        #expect(usage.cacheReadTokens == 15410)
        #expect(usage.cacheWriteTokens == 13628)
        #expect(usage.contextWindow == 1_000_000)
        #expect(usage.model == "claude-opus-5")
        // The turn still ends: usage never replaces the result.
        #expect(events.count == 2)
        if case .finished(let isError, _)? = events.last {
            #expect(!isError)
        } else {
            Issue.record("expected the turn to finish, got \(events)")
        }
    }

    // A turn a subagent ran on a cheaper model still belongs to the model that did the
    // work, which is the one that wrote the most.
    @Test func picksTheModelThatDidTheWork() throws {
        let line = """
        {"type":"result","is_error":false,"total_cost_usd":0.2,"usage":{"input_tokens":5,"output_tokens":9},\
        "modelUsage":{"claude-haiku-4-5":{"outputTokens":4,"contextWindow":200000},\
        "claude-opus-5":{"outputTokens":800,"contextWindow":1000000}}}
        """
        guard case .usage(let usage)? = StreamEvent.parse(line).first else {
            Issue.record("expected usage")
            return
        }
        #expect(usage.model == "claude-opus-5")
        #expect(usage.contextWindow == 1_000_000)
    }

    @Test func aResultWithoutCountsIsStillJustAResult() {
        let events = StreamEvent.parse("""
        {"type":"result","is_error":true,"subtype":"error","result":"boom"}
        """)
        #expect(events.count == 1)
        if case .finished(let isError, let message) = events[0] {
            #expect(isError)
            #expect(message == "boom")
        } else {
            Issue.record("expected a finished event, got \(events)")
        }
    }

    // MARK: - Rate limits

    @Test func readsAUsageWindow() throws {
        let line = """
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1785928200,\
        "rateLimitType":"five_hour","utilization":0.82,"isUsingOverage":false},"session_id":"c716258a"}
        """
        guard case .rateLimit(let limit)? = StreamEvent.parse(line).first else {
            Issue.record("expected a rate limit event")
            return
        }
        #expect(limit.kind == "five_hour")
        #expect(limit.isWarning)
        #expect(!limit.isBlocked)
        #expect(limit.utilization == 0.82)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1785928200))
        #expect(limit.title == "Current session limit")
    }

    // The window is often reported with nothing but a status, and a missing reset time
    // must not cost us the status itself.
    @Test func aWindowWithoutNumbersStillCounts() throws {
        let line = """
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day"}}
        """
        guard case .rateLimit(let limit)? = StreamEvent.parse(line).first else {
            Issue.record("expected a rate limit event")
            return
        }
        #expect(limit.isBlocked)
        #expect(limit.resetsAt == nil)
        #expect(limit.utilization == nil)
    }

    // MARK: - Adding up

    @Test func addsUpTurnsAndKeepsTheLastContext() {
        var usage = SessionUsage()
        usage.add(TurnUsage(costUSD: 0.1, inputTokens: 10, outputTokens: 5,
                            cacheReadTokens: 100, cacheWriteTokens: 20,
                            contextWindow: 200_000, model: "claude-sonnet-5"), from: .claudeCode)
        usage.noteContext(130, contextWindow: nil, model: nil, from: .claudeCode)
        usage.add(TurnUsage(costUSD: 0.2, inputTokens: 4, outputTokens: 7,
                            cacheReadTokens: 400, cacheWriteTokens: 0,
                            contextWindow: 200_000, model: "claude-sonnet-5"), from: .claudeCode)
        usage.noteContext(404, contextWindow: nil, model: nil, from: .claudeCode)

        #expect(usage.turns == 2)
        #expect(abs(usage.costUSD - 0.3) < 0.0001)
        #expect(usage.outputTokens == 12)
        #expect(usage.cacheReadTokens == 500)
        // Context is the last prompt, not the sum: it is what the next turn starts from.
        #expect(usage.contextTokens == 404)
        #expect(usage.contextFraction == 404.0 / 200_000.0)
        #expect(usage.model == "claude-sonnet-5")
    }

    // Nothing has ever run, so there is no window to measure against.
    @Test func contextIsUnknownUntilAModelReportsItsWindow() {
        var usage = SessionUsage()
        usage.add(TurnUsage(costUSD: 0.1, inputTokens: 10, outputTokens: 5), from: .claudeCode)
        #expect(usage.contextFraction == nil)
    }

    @Test func keepsTheLastModelAndContextWithTheAgentThatReportedThem() {
        var usage = SessionUsage()
        usage.add(TurnUsage(contextWindow: 1_000_000, model: "claude-fable-5"), from: .claudeCode)
        usage.noteContext(190_700, contextWindow: nil, model: nil, from: .claudeCode)

        #expect(usage.model(for: .claudeCode) == "claude-fable-5")
        #expect(usage.model(for: .codex) == nil)
        #expect(abs((usage.contextFraction(for: .claudeCode) ?? 0) - 0.1907) < 0.000001)
        #expect(usage.contextFraction(for: .codex) == nil)
    }

    @Test func aContextSnapshotCanSupplyTheModelWindow() {
        var usage = SessionUsage()
        usage.add(TurnUsage(inputTokens: 3_000, outputTokens: 200), from: .codex)
        usage.noteContext(20_970, contextWindow: 258_400,
                          model: "gpt-5.6-sol", from: .codex)

        #expect(usage.contextTokens == 20_970)
        #expect(usage.contextWindow == 258_400)
        #expect(usage.model(for: .codex) == "gpt-5.6-sol")
        #expect(abs((usage.contextFraction(for: .codex) ?? 0) - 20_970.0 / 258_400.0) < 0.000001)
    }

    // MARK: - Reading the context off a message

    // Every round of tool calls re-reads the whole conversation, so the running totals a
    // long turn reports are several times the window. The last prompt is the real size.
    @Test func readsTheContextOffTheLastPrompt() {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi!"}],\
        "usage":{"input_tokens":2,"cache_creation_input_tokens":1576,"cache_read_input_tokens":43621,\
        "output_tokens":333}},"session_id":"c716258a"}
        """
        let events = StreamEvent.parse(line)
        #expect(events.count == 2)
        guard case .context(let tokens)? = events.last else {
            Issue.record("expected a context event, got \(events)")
            return
        }
        #expect(tokens == 45199)
    }

    // A subagent fills a window of its own, and the meter is about the main conversation.
    @Test func ignoresWhatASubagentReads() {
        let line = """
        {"type":"assistant","parent_tool_use_id":"toolu_01","message":{"role":"assistant",\
        "content":[{"type":"text","text":"Looking."}],"usage":{"input_tokens":4,\
        "cache_read_input_tokens":90000,"output_tokens":12}}}
        """
        let events = StreamEvent.parse(line)
        #expect(events.count == 1)
        if case .context = events[0] {
            Issue.record("a subagent must not move the context meter")
        }
    }

    @Test func shortensLongTokenCounts() {
        #expect(formattedTokens(940) == "940")
        #expect(formattedTokens(15_410) == "15.4k")
        #expect(formattedTokens(1_240_000) == "1.2M")
    }
}
