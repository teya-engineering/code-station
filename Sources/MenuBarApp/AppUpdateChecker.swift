import AppKit
import Foundation
import Observation

struct AppUpdateRelease: Codable, Equatable, Sendable {
    let version: String
    let pageURL: URL
}

struct AppVersion: Comparable, Equatable, Sendable {
    let display: String
    private let components: [Int]

    init?(_ value: String) {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }

        let components = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber) else { return nil }
            return Int(piece)
        }
        guard components.count == pieces.count else { return nil }

        display = version
        self.components = components
    }

    static func == (left: Self, right: Self) -> Bool {
        compare(left.components, right.components) == 0
    }

    static func < (left: Self, right: Self) -> Bool {
        compare(left.components, right.components) < 0
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart ? -1 : 1 }
        }
        return 0
    }
}

@MainActor
@Observable
final class AppUpdateChecker {
    nonisolated static let checkInterval: TimeInterval = 5 * 86_400

    private(set) var availableRelease: AppUpdateRelease?
    private(set) var isChecking = false
    private(set) var dismissedVersion: String?

    @ObservationIgnored private let installedVersion: AppVersion?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let releaseEndpoint: URL

    var announcedRelease: AppUpdateRelease? {
        guard let availableRelease,
              availableRelease.version != dismissedVersion else { return nil }
        return availableRelease
    }

    init(
        installedVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        preferences: UserDefaults = .standard,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        releaseEndpoint: URL = URL(
            string: "https://api.github.com/repos/teya-engineering/code-station/releases/latest")!
    ) {
        self.installedVersion = installedVersion.flatMap(AppVersion.init)
        self.preferences = preferences
        self.session = session
        self.now = now
        self.releaseEndpoint = releaseEndpoint
        dismissedVersion = Preferences.dismissedAppUpdateVersion(in: preferences)
        availableRelease = Self.available(
            Preferences.cachedAppUpdateRelease(in: preferences),
            to: self.installedVersion)
    }

    func checkIfNeeded() async {
        guard installedVersion != nil, !isChecking else { return }
        let checkedAt = now()
        guard Self.shouldCheck(
            lastCheck: Preferences.appUpdateLastCheck(in: preferences),
            now: checkedAt) else { return }

        Preferences.setAppUpdateLastCheck(checkedAt, in: preferences)
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: releaseEndpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Teya-Code-Station", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let release = Self.decodeRelease(data) else { return }

            Preferences.setCachedAppUpdateRelease(release, in: preferences)
            availableRelease = Self.available(release, to: installedVersion)
        } catch {
            // Automatic update checks must not interrupt work when GitHub is unavailable.
        }
    }

    func dismissAnnouncement() {
        guard let version = announcedRelease?.version else { return }
        dismissedVersion = version
        Preferences.setDismissedAppUpdateVersion(version, in: preferences)
    }

    func openReleasePage() {
        guard let availableRelease else { return }
        dismissAnnouncement()
        NSWorkspace.shared.open(availableRelease.pageURL)
    }

    nonisolated static func shouldCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age < 0 || age >= checkInterval
    }

    nonisolated static func decodeRelease(_ data: Data) -> AppUpdateRelease? {
        struct GitHubRelease: Decodable {
            let tagName: String
            let pageURL: URL

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case pageURL = "html_url"
            }
        }

        guard let remote = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let version = AppVersion(remote.tagName),
              remote.pageURL.scheme == "https",
              remote.pageURL.host == "github.com" else { return nil }
        return AppUpdateRelease(version: version.display, pageURL: remote.pageURL)
    }

    private static func available(_ release: AppUpdateRelease?,
                                  to installedVersion: AppVersion?) -> AppUpdateRelease? {
        guard let release,
              let latestVersion = AppVersion(release.version),
              let installedVersion,
              latestVersion > installedVersion else { return nil }
        return release
    }
}
