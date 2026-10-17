import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaLokiPagerTests {
    private let args = Data(#"{"endRfc3339":"2026-10-02T11:00:00Z","limit":1000,"logql":"{a=\"b\"}","startRfc3339":"2026-10-02T10:00:00Z"}"#.utf8)

    // Lines newest first, one per second, starting `from` seconds after 10:00.
    private func page(_ count: Int, from: Int, sameTime: Bool = false) -> MCPHTTPClient.ToolResult {
        let entries = (0..<count).map { offset -> String in
            let second = sameTime ? from : from - offset
            let ns = (1_790_935_200 + second) * 1_000_000_000
            return #"{"timestamp":"\"\#(ns)\"","line":"l\#(from)-\#(offset)","labels":{}}"#
        }
        return .init(text: #"{"data":["# + entries.joined(separator: ",") + "]}", isError: false)
    }

    private actor Pages {
        var queue: [Result<MCPHTTPClient.ToolResult, Error>]
        var ends: [String?] = []
        init(_ queue: [Result<MCPHTTPClient.ToolResult, Error>]) { self.queue = queue }
        func next(_ arguments: Data) throws -> MCPHTTPClient.ToolResult {
            let object = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any]
            ends.append(object?["endRfc3339"] as? String)
            return try queue.removeFirst().get()
        }
    }

    @Test func stopsAtTheEndOfTheWindow() async throws {
        let pages = Pages([.success(page(3, from: 100))])
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result.count == 3)
        #expect(!outcome.capped)
    }

    @Test func walksBackFromTheOldestLine() async throws {
        let pages = Pages([.success(page(1000, from: 3000)), .success(page(10, from: 2000))])
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result.count == 1010)
        #expect(!outcome.capped)
        let ends = await pages.ends
        #expect(ends.last == "2026-10-02T10:33:21.000000001Z")
    }

    @Test func capsAtFiveThousandLines() async throws {
        let full = (0..<6).map { Result<MCPHTTPClient.ToolResult, Error>.success(page(1000, from: 9000 - $0 * 1000)) }
        let pages = Pages(full)
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result.count == 5000)
        #expect(outcome.capped)
    }

    @Test func stopsWhenAPageAddsNothingNew() async throws {
        let same = page(1000, from: 50, sameTime: true)
        let pages = Pages([.success(same), .success(same)])
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result.count == 1000)
        #expect(outcome.capped)
    }

    @Test func keepsWhatItHasWhenALaterPageFails() async throws {
        struct Lost: Error {}
        let pages = Pages([.success(page(1000, from: 3000)), .failure(Lost())])
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result.count == 1000)
        #expect(outcome.capped)
    }

    @Test func treatsAnEmptyPageAsTheEnd() async throws {
        let pages = Pages([.success(.init(text: #"{"data":[]}"#, isError: false))])
        let outcome = try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        #expect(outcome.result == .empty)
        #expect(!outcome.capped)
    }

    @Test func failsWhenTheFirstPageFails() async throws {
        let pages = Pages([.success(.init(text: "parse error at line 1", isError: true))])
        await #expect(throws: GrafanaLokiPager.Stop.failed("parse error at line 1")) {
            try await GrafanaLokiPager.run(arguments: args, levelField: nil) { try await pages.next($0) }
        }
    }
}
