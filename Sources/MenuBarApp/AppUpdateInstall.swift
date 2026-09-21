import CryptoKit
import Foundation

// Replaces the running app with the one inside a published DMG, so taking an update is a
// click rather than a download, a drag, and a Gatekeeper prompt.
//
// What makes this safe is not the checksum - that file travels beside the DMG and would
// be forged along with it - but the code requirement below. Only a bundle Apple signed
// for this team's Developer ID certificate is ever allowed to replace the running one, so
// a swapped download is refused rather than installed.
enum AppUpdateInstall {
    // The same team Scripts/release.sh signs with.
    static let teamIdentifier = "QZG8V8U2Y6"

    struct Failure: LocalizedError, Equatable {
        let reason: String

        var errorDescription: String? { reason }
    }

    // Where the update has to be written, or nil when this copy of the app cannot take
    // one: a debug build run straight from SwiftPM, a copy Gatekeeper is running from its
    // read-only translocation mirror, or one installed somewhere the user cannot write.
    static func installedBundle(
        _ bundle: URL = Bundle.main.bundleURL,
        isWritable: (String) -> Bool = FileManager.default.isWritableFile(atPath:)
    ) -> URL? {
        let app = bundle.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else { return nil }
        guard !app.path.contains("/AppTranslocation/") else { return nil }
        guard isWritable(app.deletingLastPathComponent().path) else { return nil }
        return app
    }

    // MARK: - Downloading

    static func download(
        _ url: URL,
        verifying checksumURL: URL?,
        session: URLSession,
        into directory: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var expected: String?
        if let checksumURL {
            let (data, response) = try await session.data(from: checksumURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let published = checksum(from: String(decoding: data, as: UTF8.self)) else {
                throw Failure(reason: "The checksum published for this release could not be read.")
            }
            expected = published
        }

        let (temporary, response) = try await session.download(
            for: URLRequest(url: url),
            delegate: DownloadProgress(onProgress: onProgress))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure(reason: "The update could not be downloaded.")
        }

        let dmg = directory.appendingPathComponent("update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: temporary, to: dmg)

        if let expected, try digest(of: dmg) != expected {
            try? FileManager.default.removeItem(at: dmg)
            throw Failure(reason: "The download did not match the checksum published with it.")
        }
        return dmg
    }

    // shasum writes the digest, two spaces, then the file it was taken of.
    static func checksum(from text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let value = first.lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    // Read in pieces: the image is tens of megabytes and none of it needs to be held.
    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Installing

    static func install(_ dmg: URL, version: String, over installed: URL) async throws {
        let mountRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: mountRoot) }

        let mounted = try await attach(dmg, under: mountRoot)
        do {
            try await replace(installed, withAppIn: mounted, version: version)
        } catch {
            await detach(mounted)
            throw error
        }
        await detach(mounted)
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Mounted under a directory of ours rather than in /Volumes, so an image the user
    // already has open under the same volume name does not decide where this one lands.
    private static func attach(_ dmg: URL, under root: URL) async throws -> URL {
        let result = try await CommandRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                        "-mountrandom", root.path, "-plist"],
            timeout: .seconds(180))
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.output.utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let point = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure(reason: "The downloaded disk image could not be opened.")
        }
        return URL(fileURLWithPath: point)
    }

    private static func detach(_ mounted: URL) async {
        let arguments = ["detach", mounted.path, "-quiet"]
        let result = try? await CommandRunner.run(executable: "/usr/bin/hdiutil",
                                                  arguments: arguments,
                                                  timeout: .seconds(60))
        guard result?.succeeded != true else { return }
        _ = try? await CommandRunner.run(executable: "/usr/bin/hdiutil",
                                         arguments: arguments + ["-force"],
                                         timeout: .seconds(60))
    }

    private static func replace(_ installed: URL, withAppIn mounted: URL,
                                version: String) async throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mounted, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let source = apps.first else {
            throw Failure(reason: "The disk image does not hold a single app.")
        }
        try await verifySignature(of: source)
        try verify(source, is: version)

        // Staged beside the installed app so the swap is a rename on one volume, which
        // either happens or does not. A copy written over the app in place would leave a
        // half-replaced bundle behind if anything failed part way through.
        let staged = installed.deletingLastPathComponent()
            .appendingPathComponent(".\(installed.lastPathComponent)-\(UUID().uuidString)")
        let copy = try await CommandRunner.run(executable: "/usr/bin/ditto",
                                               arguments: [source.path, staged.path],
                                               timeout: .seconds(600))
        guard copy.succeeded else {
            try? FileManager.default.removeItem(at: staged)
            throw Failure(reason: "The update could not be written to \(installed.path).")
        }
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw Failure(reason: "The update could not replace \(installed.path).")
        }
    }

    private static func verifySignature(of app: URL) async throws {
        let requirement =
            "=anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        let result = try await CommandRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--deep", "-R", requirement, app.path],
            timeout: .seconds(300))
        guard result.succeeded else {
            throw Failure(reason: "The download is not signed by Teya, so it was not installed.")
        }
    }

    // A release whose image does not carry the version its tag claims is not the update
    // that was offered, whoever built it.
    private static func verify(_ app: URL, is version: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let found = info["CFBundleShortVersionString"] as? String,
              let downloaded = AppVersion(found),
              let offered = AppVersion(version),
              downloaded == offered else {
            throw Failure(reason: "The download is not version \(version).")
        }
    }

    // MARK: - Relaunching

    // The helper outlives the app on purpose. It waits for this process to go away before
    // opening the bundle that has just replaced it, so the old and new copies never run
    // at once. It gives up after two minutes rather than opening the app long after a
    // quit that never happened.
    static func relaunchAfterExit(_ bundle: URL) throws {
        let script = """
        for _ in $(/usr/bin/seq 1 600); do
          /bin/kill -0 \(getpid()) 2>/dev/null || exec /usr/bin/open \(bundle.path.shellQuoted)
          /bin/sleep 0.2
        done
        """
        guard let null = FileHandle(forUpdatingAtPath: "/dev/null") else {
            throw Failure(reason: "The updated app could not be started.")
        }
        defer { try? null.close() }
        _ = try CommandRunner.spawnIsolatedProcess(
            executable: "/bin/sh",
            arguments: ["-c", script],
            currentDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
            standardInput: null.fileDescriptor,
            standardOutput: null.fileDescriptor,
            standardError: null.fileDescriptor,
            descriptorsToClose: [])
    }
}

// URLSession reports how far a download has got to the task's own delegate, which the
// async download API takes as an argument.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    // Required by the protocol. The async download call hands the file over itself.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { }
}
