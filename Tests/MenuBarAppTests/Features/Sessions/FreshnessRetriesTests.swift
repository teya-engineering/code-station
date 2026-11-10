import Foundation
import Testing
@testable import MenuBarApp

// A retry the user starts from a new-session card. Stopping it must leave the card as it
// was, and one that gets through must clear the failure and say so.
@MainActor
struct FreshnessRetriesTests {

    @Test func aRetryThatGetsThroughReplacesTheFailure() async throws {
        let origin = try GitRepo()
        let clone = try origin.clone()
        let failed = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 8,
                                         fetchTimedOut: true)
        let retries = FreshnessRetries()
        let id = UUID()
        var landed: GitFreshness.Report?

        retries.start(id, path: clone.path, after: failed) { landed = $0 }
        #expect(retries.attempts[id]?.wait == 30)
        #expect(!retries.isEmpty)

        #expect(await waitUntil { landed != nil })
        #expect(landed?.fetched == true)
        #expect(retries.attempts[id] == nil)
        #expect(retries.reached.contains(id))
    }

    @Test func stoppingARetrySendsNoReport() async throws {
        let origin = try GitRepo()
        let clone = try origin.clone()
        try clone.git("config", "protocol.ext.allow", "always")
        try clone.git("remote", "set-url", "origin", "ext::sh -c sleep% 10")
        let failed = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 8,
                                         fetchTimedOut: true)
        let retries = FreshnessRetries()
        let id = UUID()
        var landed: GitFreshness.Report?

        retries.start(id, path: clone.path, after: failed) { landed = $0 }
        try await Task.sleep(for: .milliseconds(300))
        retries.stop(id)
        #expect(retries.isEmpty)

        try await Task.sleep(for: .milliseconds(500))
        #expect(landed == nil)
        #expect(!retries.reached.contains(id))
    }
}
