import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The composer bar shows each choice as a state rather than a name, so the readings it
// draws have to come out the same for every agent and every run.
@MainActor
struct ComposerBarTests {
    // Default lights nothing, the lowest level one bar and the highest all four, however
    // many levels an agent has in between.
    @Test func effortLightsTheMeterFromLowestToHighest() {
        let claude = ["low", "medium", "high", "xhigh", "max"]
        #expect(EffortMeter.lit(for: nil, among: claude) == 0)
        #expect(claude.map { EffortMeter.lit(for: $0, among: claude) } == [1, 2, 3, 3, 4])

        let three = ["low", "medium", "high"]
        #expect(three.map { EffortMeter.lit(for: $0, among: three) } == [1, 3, 4])

        #expect(EffortMeter.lit(for: "high", among: ["high"]) == 4)
        #expect(EffortMeter.lit(for: "ultra", among: claude) == 0)
    }

    @Test func eachPermissionModeHasItsOwnTrustLevel() {
        #expect(TrustTone(PermissionMode.manual) == .asksEverything)
        #expect(TrustTone(PermissionMode.auto) == .risky)
        #expect(TrustTone(PermissionMode.acceptEdits) == .allowsEdits)
        #expect(TrustTone(PermissionMode.plan) == .plans)
        #expect(Set(PermissionMode.allCases.map(\.shortTitle)).count == PermissionMode.allCases.count)
        #expect(TrustTone(CodexSandboxMode.fullAccess) == .unrestricted)
        #expect(TrustTone(CopilotAccessMode.fullAccess) == .unrestricted)
    }

    @Test func aCardSaysHowItsLastRunWent() {
        let now = Date()

        #expect(summary(.stopped, started: false, now: now).text == "Never run")
        #expect(summary(.stopped, started: true, now: now).text == "Stopped")
        #expect(summary(.running(since: now), now: now).text == "Running now")
        #expect(summary(.finished(at: now.addingTimeInterval(-12 * 60)), duration: 38, now: now).text
            == "Passed 12 min ago in 38s")
        #expect(summary(.failed("no", status: 1, at: now.addingTimeInterval(-5)),
                        duration: 4.2, now: now).text
            == "Failed just now in 4.2s")
        #expect(summary(.finished(at: now.addingTimeInterval(-3 * 3_600)), duration: nil, now: now).text
            == "Passed 3 h ago")
    }

    // Colour is never the only signal: each outcome carries its own glyph as well.
    @Test func passedFailedAndRunningDifferByGlyph() {
        let now = Date()
        let glyphs = [
            summary(.running(since: now), now: now).glyph,
            summary(.finished(at: now), now: now).glyph,
            summary(.failed("no", at: now), now: now).glyph
        ]
        #expect(glyphs.allSatisfy { $0 != nil })
        #expect(Set(glyphs.compactMap { $0 }).count == 3)
    }

    @Test func timesReadAsShortlyAsTheyCan() {
        #expect(CommandRunSummary.length(4.23) == "4.2s")
        #expect(CommandRunSummary.length(38.9) == "38s")
        #expect(CommandRunSummary.length(72) == "1m 12s")
        #expect(CommandRunSummary.length(3_900) == "1h 5m")

        #expect(CommandRunSummary.elapsed(4.25) == "4.2s" || CommandRunSummary.elapsed(4.25) == "4.3s")
        #expect(CommandRunSummary.elapsed(72) == "1:12")

        #expect(CommandRunSummary.ago(59) == "just now")
        #expect(CommandRunSummary.ago(60 * 59) == "59 min ago")
        #expect(CommandRunSummary.ago(86_400 * 2) == "2 d ago")
    }

    private func summary(_ state: ShortcutStore.State, duration: TimeInterval? = nil,
                         started: Bool = true, now: Date) -> CommandRunSummary {
        CommandRunSummary(state: state, duration: duration, started: started, now: now)
    }
}
