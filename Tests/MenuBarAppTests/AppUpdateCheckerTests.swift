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

    @Test func waitsADayBetweenAutomaticChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(AppUpdateChecker.shouldCheck(lastCheck: nil, now: now))
        #expect(!AppUpdateChecker.shouldCheck(
            lastCheck: now.addingTimeInterval(-86_400 + 1), now: now))
        #expect(AppUpdateChecker.shouldCheck(
            lastCheck: now.addingTimeInterval(-86_400), now: now))
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

    @Test func readsTheSignedImageAndItsChecksumOffTheRelease() throws {
        let release = try #require(AppUpdateChecker.decodeRelease(Data("""
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/teya-engineering/code-station/releases/tag/v1.4.0",
          "assets": [
            {"name": "notes.txt",
             "browser_download_url": "https://github.com/t/c/releases/download/v1.4.0/notes.txt"},
            {"name": "TeyaCodeStation-1.4.0.dmg.sha256",
             "browser_download_url": "https://github.com/t/c/releases/download/v1.4.0/TeyaCodeStation-1.4.0.dmg.sha256"},
            {"name": "TeyaCodeStation-1.4.0.dmg",
             "browser_download_url": "https://github.com/t/c/releases/download/v1.4.0/TeyaCodeStation-1.4.0.dmg"}
          ]
        }
        """.utf8)))

        #expect(release.downloadURL?.lastPathComponent == "TeyaCodeStation-1.4.0.dmg")
        #expect(release.checksumURL?.lastPathComponent == "TeyaCodeStation-1.4.0.dmg.sha256")
        #expect(release.canInstall)
    }

    // An asset served from anywhere other than GitHub is not what the release published.
    @Test func ignoresAnImageHostedSomewhereElse() throws {
        let release = try #require(AppUpdateChecker.decodeRelease(Data("""
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/teya-engineering/code-station/releases/tag/v1.4.0",
          "assets": [
            {"name": "TeyaCodeStation-1.4.0.dmg",
             "browser_download_url": "https://example.com/TeyaCodeStation-1.4.0.dmg"}
          ]
        }
        """.utf8)))

        #expect(release.downloadURL == nil)
        #expect(!release.canInstall)
    }

    @MainActor
    @Test func offersToInstallOnlyWhenTheAppCanReplaceItself() throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let installable = AppUpdateRelease(
            version: "2.0.0",
            pageURL: URL(string: "https://github.com/t/c/releases/tag/v2.0.0")!,
            downloadURL: URL(string: "https://github.com/t/c/releases/download/v2.0.0/app.dmg")!)
        let bundle = URL(fileURLWithPath: "/Applications/Teya Code Station.app")

        Preferences.setCachedAppUpdateRelease(installable, in: preferences)
        #expect(AppUpdateChecker(installedVersion: "1.0.0", preferences: preferences,
                                 installTarget: { bundle }).canInstallInPlace)
        #expect(!AppUpdateChecker(installedVersion: "1.0.0", preferences: preferences,
                                  installTarget: { nil }).canInstallInPlace)

        Preferences.setCachedAppUpdateRelease(
            AppUpdateRelease(version: "2.0.0", pageURL: installable.pageURL), in: preferences)
        #expect(!AppUpdateChecker(installedVersion: "1.0.0", preferences: preferences,
                                  installTarget: { bundle }).canInstallInPlace)
    }

    @Test func refusesToWriteOverACopyThatCannotTakeAnUpdate() {
        let app = URL(fileURLWithPath: "/Applications/Teya Code Station.app")

        #expect(AppUpdateInstall.installedBundle(app, isWritable: { _ in true })?
            .lastPathComponent == "Teya Code Station.app")
        #expect(AppUpdateInstall.installedBundle(app, isWritable: { _ in false }) == nil)
        // A debug build run straight from SwiftPM is a bare executable, not a bundle.
        #expect(AppUpdateInstall.installedBundle(URL(fileURLWithPath: "/tmp/build/MenuBarApp"),
                                                 isWritable: { _ in true }) == nil)
        // Gatekeeper runs a quarantined copy from a read-only mirror of its own.
        #expect(AppUpdateInstall.installedBundle(
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/A/d/Teya.app"),
            isWritable: { _ in true }) == nil)
    }

    @Test func readsTheDigestOutOfAPublishedChecksumFile() {
        #expect(AppUpdateInstall.checksum(
            from: "AB\(String(repeating: "c", count: 62))  TeyaCodeStation-1.4.0.dmg\n")
            == "ab\(String(repeating: "c", count: 62))")
        #expect(AppUpdateInstall.checksum(from: "") == nil)
        #expect(AppUpdateInstall.checksum(from: "deadbeef  short.dmg") == nil)
        #expect(AppUpdateInstall.checksum(
            from: "\(String(repeating: "z", count: 64))  not-hex.dmg") == nil)
    }

    @Test func keepsADownloadOnlyWhenItMatchesThePublishedChecksum() async throws {
        let image = Data("a signed disk image".utf8)
        let directory = try AppUpdateInstall.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("digest-me")
        try image.write(to: file)
        let digest = try AppUpdateInstall.digest(of: file)

        let dmg = URL(string: "https://github.com/t/c/releases/download/v1/app.dmg")!
        let checksum = URL(string: "https://github.com/t/c/releases/download/v1/app.dmg.sha256")!
        AppUpdateURLProtocol.prepare(routes: [
            dmg.path: (200, image),
            checksum.path: (200, Data("\(digest)  app.dmg\n".utf8))
        ])

        let downloaded = try await AppUpdateInstall.download(
            dmg, verifying: checksum, session: stubSession(), into: directory) { _ in }
        #expect(try Data(contentsOf: downloaded) == image)

        AppUpdateURLProtocol.prepare(routes: [
            dmg.path: (200, Data("something else entirely".utf8)),
            checksum.path: (200, Data("\(digest)  app.dmg\n".utf8))
        ])
        await #expect(throws: AppUpdateInstall.Failure.self) {
            try await AppUpdateInstall.download(
                dmg, verifying: checksum, session: stubSession(), into: directory) { _ in }
        }
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
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var receivedHeaders: [String: String] = [:]
    nonisolated(unsafe) private static var receivedRequestCount = 0
    private static let stateLock = NSLock()

    static var requestCount: Int { stateLock.withLock { receivedRequestCount } }
    static var headers: [String: String] { stateLock.withLock { receivedHeaders } }

    static func prepare(status: Int, body: Data) {
        stateLock.withLock {
            responseStatus = status
            responseBody = body
            routes = [:]
            receivedHeaders = [:]
            receivedRequestCount = 0
        }
    }

    static func prepare(routes: [String: (status: Int, body: Data)]) {
        stateLock.withLock {
            self.routes = routes
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
            if let route = Self.routes[request.url?.path ?? ""] {
                return (route.status, route.body)
            }
            return Self.routes.isEmpty ? (Self.responseStatus, Self.responseBody) : (404, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
