import AppKit
import Foundation
import Observation

struct AppUpdateRelease: Codable, Equatable, Sendable {
    let version: String
    let pageURL: URL
    // The signed image and the checksum published beside it. Optional so a release cached
    // by an older build still reads back; without them the update is only a link.
    var downloadURL: URL?
    var checksumURL: URL?

    var canInstall: Bool { downloadURL != nil }
}

// How far the app has got with taking an update.
enum AppUpdateInstallState: Equatable, Sendable {
    case idle
    case downloading(Double)
    case installing
    case ready
    case failed(String)

    // Progress inside a step is still the same piece of news, so something answered once
    // about a download is not asked again as the numbers move.
    enum Stage: Equatable { case idle, working, ready, failed }

    var stage: Stage {
        switch self {
        case .idle: .idle
        case .downloading, .installing: .working
        case .ready: .ready
        case .failed: .failed
        }
    }
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
    private(set) var installState = AppUpdateInstallState.idle

    @ObservationIgnored private let installedVersion: AppVersion?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let releaseEndpoint: URL
    @ObservationIgnored private let installTarget: () -> URL?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    var announcedRelease: AppUpdateRelease? {
        guard let availableRelease,
              availableRelease.version != dismissedVersion else { return nil }
        return availableRelease
    }

    // A debug build, or a copy installed where it cannot write over itself, can still be
    // told about an update; it just has to be taken by hand.
    var canInstallInPlace: Bool {
        availableRelease?.canInstall == true && installTarget() != nil
    }

    init(
        installedVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        preferences: UserDefaults = .standard,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        releaseEndpoint: URL = URL(
            string: "https://api.github.com/repos/teya-engineering/code-station/releases/latest")!,
        installTarget: @escaping () -> URL? = { AppUpdateInstall.installedBundle() }
    ) {
        self.installedVersion = installedVersion.flatMap(AppVersion.init)
        self.preferences = preferences
        self.session = session
        self.now = now
        self.releaseEndpoint = releaseEndpoint
        self.installTarget = installTarget
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

    // For the places where the page is how the update is taken, so going there is acting
    // on the announcement and there is nothing left to say.
    func openReleasePage() {
        guard let availableRelease else { return }
        dismissAnnouncement()
        NSWorkspace.shared.open(availableRelease.pageURL)
    }

    // Reading what changed is not taking the update, so the offer stays on screen.
    func openReleaseNotes() {
        guard let availableRelease else { return }
        NSWorkspace.shared.open(availableRelease.pageURL)
    }

    // Fetches the signed image, checks it, and swaps it in, leaving the running app to
    // finish whatever it is doing. Nothing restarts until the person says so.
    func installUpdate() {
        guard installTask == nil, installState != .ready,
              let release = availableRelease, let downloadURL = release.downloadURL,
              let installed = installTarget() else { return }

        installState = .downloading(0)
        installTask = Task { [self] in
            defer { installTask = nil }
            do {
                let directory = try AppUpdateInstall.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }

                let dmg = try await AppUpdateInstall.download(
                    downloadURL,
                    verifying: release.checksumURL,
                    session: session,
                    into: directory
                ) { fraction in
                    Task { @MainActor in
                        // A fraction that arrives after the download finished belongs to
                        // a step that is already over.
                        guard case .downloading = self.installState else { return }
                        self.installState = .downloading(fraction)
                    }
                }
                installState = .installing
                try await AppUpdateInstall.install(dmg, version: release.version,
                                                   over: installed)
                installState = .ready
            } catch {
                installState = .failed(error.localizedDescription)
            }
        }
    }

    // The new bundle is already in place, so quitting alone is enough to take the update;
    // the helper only saves the person from starting the app again by hand.
    func relaunch() {
        guard installState == .ready, let installed = installTarget() else { return }
        do {
            try AppUpdateInstall.relaunchAfterExit(installed)
        } catch {
            installState = .failed(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }


    nonisolated static func shouldCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age < 0 || age >= checkInterval
    }

    nonisolated static func decodeRelease(_ data: Data) -> AppUpdateRelease? {
        struct GitHubRelease: Decodable {
            struct Asset: Decodable {
                let name: String
                let downloadURL: URL

                enum CodingKeys: String, CodingKey {
                    case name
                    case downloadURL = "browser_download_url"
                }
            }

            let tagName: String
            let pageURL: URL
            let assets: [Asset]?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case pageURL = "html_url"
                case assets
            }
        }

        guard let remote = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let version = AppVersion(remote.tagName),
              isGitHub(remote.pageURL) else { return nil }

        let assets = (remote.assets ?? []).filter { isGitHub($0.downloadURL) }
        let image = assets.first { $0.name.hasSuffix(".dmg") }
        return AppUpdateRelease(
            version: version.display,
            pageURL: remote.pageURL,
            downloadURL: image?.downloadURL,
            checksumURL: image.flatMap { image in
                assets.first { $0.name == image.name + ".sha256" }?.downloadURL
            })
    }

    private nonisolated static func isGitHub(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
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
