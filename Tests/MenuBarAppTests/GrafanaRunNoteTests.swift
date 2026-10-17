import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaRunNoteTests {
    @Test func listsRunsWithCountsOnly() {
        let text = GrafanaRunNote.text([
            .init(server: "grafana-cde-dev", query: #"{a="b"} |= "timeout""#, window: "last 1h",
                  count: 342, capped: true, failed: false),
            .init(server: "grafana-cde-dev", query: "up", window: "same window",
                  count: 0, capped: false, failed: true),
        ])
        #expect(text == """
            Since your last answer the user ran these Grafana queries themselves (counts only):
            - `{a="b"} |= "timeout"` over last 1h on grafana-cde-dev → 342 lines (capped)
            - `up` over same window on grafana-cde-dev → failed
            """)
    }

    @Test func saysNothingWithoutRuns() {
        #expect(GrafanaRunNote.text([]) == nil)
    }

    @Test func labelsAChip() {
        var run = GrafanaRun(query: "q", window: .last(seconds: 3600))
        #expect(run.chipLabel == "you · running · last 1h")
        run.isRunning = false
        run.result = .logs([], truncated: false)
        run.capped = true
        #expect(run.chipLabel == "you · 0 lines (capped) · last 1h")
        run.result = nil
        run.error = "boom"
        #expect(run.chipLabel == "you · failed · last 1h")
    }
}

struct GrafanaServerReadinessTests {
    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @Test func waitsUntilTheServerAnswers() async throws {
        let attempts = Attempts()
        try await GrafanaQueryRunner.waitUntilReady(attempts: 5, delay: .milliseconds(1),
                                                    failure: { nil }) {
            if await attempts.next() < 3 { throw URLError(.cannotConnectToHost) }
        }
        #expect(await attempts.count == 3)
    }

    @Test func reportsWhyTheServerStopped() async throws {
        await #expect(throws: GrafanaLokiPager.Stop.failed("address already in use")) {
            try await GrafanaQueryRunner.waitUntilReady(attempts: 5, delay: .milliseconds(1),
                                                        failure: { "address already in use" }) {
                throw URLError(.cannotConnectToHost)
            }
        }
    }

    @Test func givesUpAfterTheLastAttempt() async throws {
        await #expect(throws: GrafanaLokiPager.Stop.self) {
            try await GrafanaQueryRunner.waitUntilReady(attempts: 2, delay: .milliseconds(1),
                                                        failure: { nil }) {
                throw URLError(.cannotConnectToHost)
            }
        }
    }
}
