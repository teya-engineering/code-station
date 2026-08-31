import Foundation
import Testing
@testable import MenuBarApp

@Suite(.serialized)
struct AppUpdateCheckerTests {
    @Test func comparesNumericVersionComponents() throws {
        let newer = try #require(AppVersion("1.10.0"))
        let older = try #require(AppVersion("1.9.9"))

        #expect(newer > older)
        #expect(AppVersion("v2.0") == AppVersion("2.0.0"))
        #expect(AppVersion("1.0-beta") == nil)
        #expect(AppVersion("1..0") == nil)
    }

    @Test func waitsFiveDaysBetweenAutomaticChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(AppUpdateChecker.shouldCheck(lastCheck: nil, now: now))
        #expect(!AppUpdateChecker.shouldCheck(
            lastCheck: now.addingTimeInterval(-5 * 86_400 + 1), now: now))
        #expect(AppUpdateChecker.shouldCheck(
            lastCheck: now.addingTimeInterval(-5 * 86_400), now: now))
    }

    @MainActor
    @Test func findsAndCachesANewerPublishedRelease() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AppUpdateURLProtocol.prepare(status: 200, body: release(version: "v1.3.0"))
        let checker = AppUpdateChecker(installedVersion: "1.2.4",
                                       preferences: preferences,
                                       session: stubSession(),
                                       now: { now },
                                       releaseEndpoint: URL(string: "https://example.test/latest")!)

        await checker.checkIfNeeded()

        #expect(checker.availableRelease == AppUpdateRelease(
            version: "1.3.0",
            pageURL: URL(string: "https://github.com/teya-engineering/code-station/releases/tag/v1.3.0")!))
        #expect(checker.announcedRelease == checker.availableRelease)
        #expect(Preferences.appUpdateLastCheck(in: preferences) == now)
        #expect(Preferences.cachedAppUpdateRelease(in: preferences) == checker.availableRelease)
        #expect(AppUpdateURLProtocol.requestCount == 1)
        #expect(AppUpdateURLProtocol.headers["Accept"] == "application/vnd.github+json")
        #expect(AppUpdateURLProtocol.headers["X-GitHub-Api-Version"] == "2026-03-10")

        await checker.checkIfNeeded()

        #expect(AppUpdateURLProtocol.requestCount == 1)
    }

    @MainActor
    @Test func aFailedAttemptAlsoWaitsFiveDaysBeforeRetrying() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AppUpdateURLProtocol.prepare(status: 503, body: Data())
        let checker = AppUpdateChecker(installedVersion: "1.0.0",
                                       preferences: preferences,
                                       session: stubSession(),
                                       now: { now },
                                       releaseEndpoint: URL(string: "https://example.test/latest")!)

        await checker.checkIfNeeded()
        await checker.checkIfNeeded()

        #expect(AppUpdateURLProtocol.requestCount == 1)
        #expect(Preferences.appUpdateLastCheck(in: preferences) == now)
        #expect(checker.availableRelease == nil)
    }

    @MainActor
    @Test func dismissalSurvivesRelaunchButTheUpdateRemainsAvailable() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let update = AppUpdateRelease(
            version: "2.0.0",
            pageURL: URL(string: "https://github.com/teya-engineering/code-station/releases/tag/v2.0.0")!)
        Preferences.setCachedAppUpdateRelease(update, in: preferences)
        let checker = AppUpdateChecker(installedVersion: "1.9.0", preferences: preferences)

        checker.dismissAnnouncement()
        let relaunched = AppUpdateChecker(installedVersion: "1.9.0", preferences: preferences)

        #expect(relaunched.availableRelease == update)
        #expect(relaunched.announcedRelease == nil)
        #expect(Preferences.dismissedAppUpdateVersion(in: preferences) == "2.0.0")
    }

    @MainActor
    @Test func ignoresCurrentOlderAndInvalidReleases() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        Preferences.setCachedAppUpdateRelease(
            AppUpdateRelease(
                version: "1.2.0",
                pageURL: URL(string: "https://github.com/teya-engineering/code-station/releases/tag/v1.2.0")!),
            in: preferences)

        #expect(AppUpdateChecker(installedVersion: "1.2", preferences: preferences)
            .availableRelease == nil)
        #expect(AppUpdateChecker(installedVersion: "1.3.0", preferences: preferences)
            .availableRelease == nil)
        #expect(AppUpdateChecker(installedVersion: nil, preferences: preferences)
            .availableRelease == nil)
        #expect(AppUpdateChecker.decodeRelease(Data("""
        {"tag_name":"v1.4.0","html_url":"http://example.com/download"}
        """.utf8)) == nil)
    }

    private func preferences() throws -> (UserDefaults, String) {
        let suite = "app-update-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func release(version: String) -> Data {
        Data("""
        {
          "tag_name": "\(version)",
          "html_url": "https://github.com/teya-engineering/code-station/releases/tag/\(version)"
        }
        """.utf8)
    }
}

private final class AppUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var receivedHeaders: [String: String] = [:]
    nonisolated(unsafe) private static var receivedRequestCount = 0
    private static let stateLock = NSLock()

    static var requestCount: Int { stateLock.withLock { receivedRequestCount } }
    static var headers: [String: String] { stateLock.withLock { receivedHeaders } }

    static func prepare(status: Int, body: Data) {
        stateLock.withLock {
            responseStatus = status
            responseBody = body
            receivedHeaders = [:]
            receivedRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.stateLock.withLock {
            Self.receivedHeaders = request.allHTTPHeaderFields ?? [:]
            Self.receivedRequestCount += 1
            return (Self.responseStatus, Self.responseBody)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
