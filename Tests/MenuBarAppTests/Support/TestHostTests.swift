import CoreFoundation
import Foundation
import Testing

@MainActor
struct TestHostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_STATION_TEST_HOST"] == "1",
                   "Requires the CI test host"))
    func stoppingTheRunLoopDoesNotEndTheTestRun() async throws {
        CFRunLoopStop(CFRunLoopGetMain())
        try await Task.sleep(for: .milliseconds(20))
        await MainActor.run { #expect(Thread.isMainThread) }
    }
}
