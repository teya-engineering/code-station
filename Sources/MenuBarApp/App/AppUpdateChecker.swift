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

// What a check asked for by hand found, so the place that asked can say so.
enum AppUpdateCheckOutcome: Equatable, Sendable {
    case available(String)
    case upToDate
    case failed
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
    // Four checks a day keep releases visible without nearing GitHub's anonymous limit.
    nonisolated static let checkInterval: TimeInterval = 21_600
    // The app can stay open for days. Waking hourly lets failed checks try again,
    // while successful checks still wait six hours.
    nonisolated static let wakeInterval: Duration = .seconds(3_600)

    private(set) var availableRelease: AppUpdateRelease?
    private(set) var isChecking = false
    private(set) var dismissedVersion: String?
    private(set) var installState = AppUpdateInstallState.idle {
        didSet {
            if installState.stage != oldValue.stage { dismissedInstallStage = nil }
        }
    }
    private(set) var isRelaunching = false
    private(set) var lastCheck: Date?
    // The window animates a manual check's answer without animating background checks.
    private(set) var manualCheckAnnouncements = 0
    // Counts each time the release page is opened in the browser. The page opens outside
    // the window, so the window watches this to leave a note that the click landed.
    private(set) var releasePageOpenings = 0
    private var dismissedInstallStage: AppUpdateInstallState.Stage?

    @ObservationIgnored private let installedVersion: AppVersion?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let releaseEndpoint: URL
    @ObservationIgnored private let installTarget: () -> URL?
    @ObservationIgnored private let install: @Sendable (URL, String, URL) async throws -> Void
    @ObservationIgnored private var installTask: Task<Void, Never>?

    var announcedRelease: AppUpdateRelease? {
        guard let availableRelease,
              availableRelease.version != dismissedVersion else { return nil }
        return availableRelease
    }

    // Dismissing an offer does not hide the work started from it. Each install stage
    // can be put away until the person asks to see the update again.
    var bannerRelease: AppUpdateRelease? {
        let stage = installState.stage
        guard stage != dismissedInstallStage else { return nil }
        return stage == .idle ? announcedRelease : availableRelease
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
        installTarget: @escaping () -> URL? = { AppUpdateInstall.installedBundle() },
        install: @escaping @Sendable (URL, String, URL) async throws -> Void = AppUpdateInstall.install
    ) {
        self.installedVersion = installedVersion.flatMap(AppVersion.init)
        self.preferences = preferences
        self.session = session
        self.now = now
        self.releaseEndpoint = releaseEndpoint
        self.installTarget = installTarget
        self.install = install
        dismissedVersion = Preferences.dismissedAppUpdateVersion.read(in: preferences)
        lastCheck = Preferences.appUpdateLastCheck(in: preferences)
        availableRelease = Self.available(
            Preferences.cachedAppUpdateRelease(in: preferences),
            to: self.installedVersion)
    }

    func keepChecking() async {
        while !Task.isCancelled {
            await checkIfNeeded()
            try? await Task.sleep(for: Self.wakeInterval)
        }
    }

    func checkIfNeeded() async {
        guard installedVersion != nil, !isChecking else { return }
        guard Self.shouldCheck(
            lastCheck: Preferences.appUpdateLastCheck(in: preferences),
            now: now()) else { return }
        // Automatic update checks must not interrupt work when GitHub is unavailable.
        _ = await check()
    }

    // Asked for by hand, so it ignores the wait between checks. Asking is also wanting to
    // hear the answer, so a version whose announcement was put away is announced again.
    func checkNow() async -> AppUpdateCheckOutcome {
        guard installedVersion != nil, !isChecking else { return .failed }
        let outcome = await check()
        if case .available(let version) = outcome {
            dismissedInstallStage = nil
            if version == dismissedVersion {
                dismissedVersion = nil
                Preferences.dismissedAppUpdateVersion.write(nil, in: preferences)
            }
            manualCheckAnnouncements += 1
        }
        return outcome
    }

    private func check() async -> AppUpdateCheckOutcome {
        let checkedAt = now()
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: releaseEndpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Teya-Code-Station", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return .failed }
            // GitHub answered, so the wait starts now even if there is no release worth
            // offering. Only a check that never got an answer is tried again sooner.
            Preferences.setAppUpdateLastCheck(checkedAt, in: preferences)
            lastCheck = checkedAt
            guard let release = Self.decodeRelease(data) else { return .failed }

            Preferences.setCachedAppUpdateRelease(release, in: preferences)
            availableRelease = Self.available(release, to: installedVersion)
            return availableRelease.map { .available($0.version) } ?? .upToDate
        } catch {
            return .failed
        }
    }

    func dismissAnnouncement() {
        guard let version = announcedRelease?.version else { return }
        dismissedVersion = version
        Preferences.dismissedAppUpdateVersion.write(version, in: preferences)
    }

    func dismissBanner() {
        if installState.stage == .idle {
            dismissAnnouncement()
        } else {
            dismissedInstallStage = installState.stage
        }
    }

    // For the places where the page is how the update is taken, so going there is acting
    // on the announcement and there is nothing left to say.
    func openReleasePage() {
        guard let availableRelease else { return }
        dismissAnnouncement()
        NSWorkspace.shared.open(availableRelease.pageURL)
        releasePageOpenings += 1
    }

    // Reading what changed is not taking the update, so the offer stays on screen.
    func openReleaseNotes() {
        guard let availableRelease else { return }
        NSWorkspace.shared.open(availableRelease.pageURL)
        releasePageOpenings += 1
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
                try await install(dmg, release.version, installed)
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
        isRelaunching = true
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
