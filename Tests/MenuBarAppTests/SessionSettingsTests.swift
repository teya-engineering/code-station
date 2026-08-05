import Foundation
import Testing
@testable import MenuBarApp

// What a session runs with, and what it reads back off the CLI about the cost. The
// payloads here are real ones taken off the wire.
struct SessionSettingsTests {

    // MARK: - Arguments

    private let appDefaults = SessionSettings(permissionMode: "acceptEdits")

    @Test func leavesUnsetChoicesOffTheCommandLine() {
        let arguments = SessionRunner.arguments(settings: SessionSettings(), defaults: appDefaults)
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--effort"))
        #expect(!arguments.contains("--add-dir"))
        #expect(!arguments.contains("--resume"))
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
    }

    // A session that has chosen nothing runs on the app settings, which is what the
    // "use the default" rows promise.
    @Test func fallsBackToTheAppDefaults() {
        let defaults = SessionSettings(model: "sonnet", effort: "low", permissionMode: "auto")
        let arguments = SessionRunner.arguments(settings: SessionSettings(), defaults: defaults)
        #expect(pair(arguments, after: "--model") == "sonnet")
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
    }

    // Nothing chosen anywhere still has to name a mode: the app is what shows the
    // questions, so it never leaves that to the CLI's own configuration.
    @Test func alwaysNamesAPermissionMode() {
        let arguments = SessionRunner.arguments(settings: SessionSettings(),
                                                defaults: SessionSettings())
        #expect(pair(arguments, after: "--permission-mode") == "acceptEdits")
    }

    private func pair(_ arguments: [String], after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
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
        // Cached tokens are still in the window, so they count towards the context.
        #expect(usage.contextTokens == 29040)
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
                            contextWindow: 200_000, model: "claude-sonnet-5"))
        usage.add(TurnUsage(costUSD: 0.2, inputTokens: 4, outputTokens: 7,
                            cacheReadTokens: 400, cacheWriteTokens: 0,
                            contextWindow: 200_000, model: "claude-sonnet-5"))

        #expect(usage.turns == 2)
        #expect(abs(usage.costUSD - 0.3) < 0.0001)
        #expect(usage.outputTokens == 12)
        #expect(usage.cacheReadTokens == 500)
        // Context is the last turn's, not the sum: it is what the next turn starts from.
        #expect(usage.contextTokens == 404)
        #expect(usage.contextFraction == 404.0 / 200_000.0)
        #expect(usage.model == "claude-sonnet-5")
    }

    // Nothing has ever run, so there is no window to measure against.
    @Test func contextIsUnknownUntilAModelReportsItsWindow() {
        var usage = SessionUsage()
        usage.add(TurnUsage(costUSD: 0.1, inputTokens: 10, outputTokens: 5))
        #expect(usage.contextFraction == nil)
    }

    @Test func shortensLongTokenCounts() {
        #expect(formattedTokens(940) == "940")
        #expect(formattedTokens(15_410) == "15.4k")
        #expect(formattedTokens(1_240_000) == "1.2M")
    }
}
