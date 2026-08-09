import Foundation
import Testing
@testable import MenuBarApp

@Suite(.serialized)
struct PostmanRunnerTests {
    @MainActor
    @Test func truncatesResponsesAtTheConfiguredLimit() async throws {
        StubURLProtocol.prepare(body: Data(repeating: 97, count: 100), chunkSize: 20)
        let runner = PostmanRunner(maxResponseBytes: 32,
                                   maxRetainedResultBytes: 128,
                                   sessionConfiguration: stubConfiguration())
        let request = SavedRequest(name: "large", url: "https://example.test/large")

        await runner.send(request, environment: .staging)

        let result = try #require(runner.result(request.id, in: .staging))
        #expect(result.body == String(repeating: "a", count: 32))
        #expect(result.byteCount == 100)
        #expect(result.isTruncated)
        #expect(StubURLProtocol.wasStopped)
    }

    @MainActor
    @Test func evictsOldResultsWhenTheRetainedBudgetIsFull() async {
        StubURLProtocol.prepare(body: Data(repeating: 97, count: 8))
        let runner = PostmanRunner(maxResponseBytes: 8,
                                   maxRetainedResultBytes: 56,
                                   sessionConfiguration: stubConfiguration())
        let requests = (0..<3).map {
            SavedRequest(name: "request-\($0)", url: "https://example.test/\($0)")
        }

        for request in requests {
            await runner.send(request, environment: .staging)
        }

        #expect(runner.result(requests[0].id, in: .staging) == nil)
        #expect(runner.result(requests[1].id, in: .staging) != nil)
        #expect(runner.result(requests[2].id, in: .staging) != nil)
    }

    @MainActor
    @Test func cancellationEndsTheRequestAndReportsWhatHappened() async throws {
        StubURLProtocol.prepare(body: Data("late".utf8), delay: 10)
        let runner = PostmanRunner(maxResponseBytes: 32,
                                   maxRetainedResultBytes: 64,
                                   sessionConfiguration: stubConfiguration())
        let request = SavedRequest(name: "slow", url: "https://example.test/slow")
        let sending = Task { await runner.send(request, environment: .staging) }

        while !runner.isRunning(request.id, in: .staging) {
            await Task.yield()
        }
        runner.cancel(request.id, in: .staging)
        await sending.value

        let result = try #require(runner.result(request.id, in: .staging))
        #expect(result.failure == "Cancelled.")
        #expect(!runner.isRunning(request.id, in: .staging))
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var responseDelay: TimeInterval = 0
    nonisolated(unsafe) private static var responseChunkSize: Int?
    nonisolated(unsafe) private static var stopped = false
    private static let stateLock = NSLock()

    private let instanceLock = NSLock()
    private var responseWork: DispatchWorkItem?
    private var isStopped = false

    static var wasStopped: Bool { stateLock.withLock { stopped } }
    static func prepare(body: Data, delay: TimeInterval = 0, chunkSize: Int? = nil) {
        stateLock.withLock {
            responseBody = body
            responseDelay = delay
            responseChunkSize = chunkSize
            stopped = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, delay, chunkSize) = Self.stateLock.withLock {
            (Self.responseBody, Self.responseDelay, Self.responseChunkSize)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(body.count)"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.deliver(body, offset: 0, chunkSize: chunkSize ?? body.count)
        }
        instanceLock.withLock { responseWork = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() {
        instanceLock.withLock {
            isStopped = true
            responseWork?.cancel()
            responseWork = nil
        }
        Self.stateLock.withLock { Self.stopped = true }
    }

    private func deliver(_ body: Data, offset: Int, chunkSize: Int) {
        guard !instanceLock.withLock({ isStopped }) else { return }
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let end = min(offset + max(1, chunkSize), body.count)
        client?.urlProtocol(self, didLoad: body[offset..<end])

        let work = DispatchWorkItem { [weak self] in
            self?.deliver(body, offset: end, chunkSize: chunkSize)
        }
        instanceLock.withLock { responseWork = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
