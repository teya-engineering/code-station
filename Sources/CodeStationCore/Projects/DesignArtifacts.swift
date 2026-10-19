import Foundation

public enum DesignPhase: String, Codable, Equatable, Sendable {
    case designing
    case implementing
}

public struct DesignScreen: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public var width: Int?
    public var height: Int?

    public static let canvas = DesignScreen(id: "canvas", title: "Canvas", path: "index.html")
}

public struct DesignManifest: Codable, Equatable, Sendable {
    public var screens: [DesignScreen]

    public static let singleScreen = DesignManifest(screens: [.canvas])

    public static func read(from directory: URL) -> DesignManifest {
        let url = directory.appendingPathComponent("design.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DesignManifest.self, from: data) else {
            return .singleScreen
        }
        let screens = decoded.screens.filter { screen in
            guard !screen.id.isEmpty, !screen.title.isEmpty else { return false }
            return safeURL(for: screen, in: directory) != nil
        }
        return screens.isEmpty ? .singleScreen : DesignManifest(screens: screens)
    }

    public static func safeURL(for screen: DesignScreen, in directory: URL) -> URL? {
        let root = directory.standardizedFileURL
        let candidate = root.appendingPathComponent(screen.path).standardizedFileURL
        guard candidate.path.pathRelative(to: root.path) != nil,
              candidate.pathExtension.lowercased() == "html",
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

public struct DesignRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let number: Int
    let createdAt: Date
    let sourceRevisions: [String: String]
    let screens: [DesignScreen]
    // The prompt whose turn produced this version, so the version can sit next to the
    // words that made it. Nil for versions saved by hand before every turn kept one.
    var promptID: UUID? = nil

    public var title: String { "Design v\(number)" }
}

public struct DesignArtifactRevision: Equatable, Sendable {
    public struct FileRevision: Equatable, Sendable {
        public let path: String
        public let modified: Date
        public let size: Int
    }

    public let files: [FileRevision]

    public static func read(_ directory: URL) -> DesignArtifactRevision? {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var files: [FileRevision] = []
        for case let url as URL in enumerator {
            let relative = url.path.pathRelative(to: directory.path) ?? url.lastPathComponent
            if relative == "revisions" || relative.hasPrefix("revisions/")
                || relative == "reference" || relative.hasPrefix("reference/") {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            files.append(FileRevision(path: relative,
                                      modified: modified,
                                      size: values.fileSize ?? 0))
        }
        guard !files.isEmpty else { return nil }
        return DesignArtifactRevision(files: files.sorted { $0.path < $1.path })
    }
}

public enum DesignArtifacts {
    public enum Failure: LocalizedError, Equatable {
        case noDesign
        case couldNotSave(String)

        public var errorDescription: String? {
            switch self {
            case .noDesign:
                "There is no Design to hand over yet."
            case .couldNotSave(let detail):
                "The Design revision could not be saved: \(detail)"
            }
        }
    }

    // Whether the live canvas holds exactly the files this version saved. A saved
    // version may carry a handoff note the live canvas never had, so that one file
    // only counts when the live canvas has it too.
    public static func matchesLive(_ revision: DesignRevision, designDirectory: URL) -> Bool {
        guard let live = DesignArtifactRevision.read(designDirectory),
              let saved = DesignArtifactRevision.read(
                materialsDirectory(revision, designDirectory: designDirectory))
        else { return false }
        let liveHasHandoff = live.files.contains { $0.path == "handoff.md" }
        let savedFiles = saved.files.filter { liveHasHandoff || $0.path != "handoff.md" }
        guard savedFiles.map(\.path) == live.files.map(\.path) else { return false }
        let materials = materialsDirectory(revision, designDirectory: designDirectory)
        // A copy normally keeps its file dates, which settles most files without reading
        // them. Where a date differs, the bytes decide.
        return zip(savedFiles, live.files).allSatisfy { savedFile, liveFile in
            if savedFile == liveFile { return true }
            guard savedFile.size == liveFile.size else { return false }
            let savedData = try? Data(contentsOf: materials.appendingPathComponent(savedFile.path))
            let liveData = try? Data(contentsOf: designDirectory.appendingPathComponent(liveFile.path))
            return savedData != nil && savedData == liveData
        }
    }

    static func revisionDirectory(_ revision: DesignRevision,
                                  designDirectory: URL) -> URL {
        designDirectory
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revision.id.uuidString, isDirectory: true)
    }

    public static func materialsDirectory(_ revision: DesignRevision,
                                   designDirectory: URL) -> URL {
        revisionDirectory(revision, designDirectory: designDirectory)
            .appendingPathComponent("materials", isDirectory: true)
    }

    static func previewURL(_ revision: DesignRevision,
                           designDirectory: URL) -> URL {
        revisionDirectory(revision, designDirectory: designDirectory)
            .appendingPathComponent("preview.png")
    }

    static func saveRevision(_ revision: DesignRevision,
                             from designDirectory: URL,
                             screenshot: Data?,
                             fallbackHandoff: String) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: designDirectory.appendingPathComponent("index.html").path)
        else { throw Failure.noDesign }

        let revisionDirectory = revisionDirectory(revision, designDirectory: designDirectory)
        let materials = materialsDirectory(revision, designDirectory: designDirectory)
        do {
            try files.createDirectory(at: materials, withIntermediateDirectories: true)
            for entry in try files.contentsOfDirectory(
                at: designDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) where !reservedLiveEntry(entry.lastPathComponent) {
                try files.copyItem(at: entry,
                                   to: materials.appendingPathComponent(entry.lastPathComponent))
            }
            let handoff = materials.appendingPathComponent("handoff.md")
            if !files.fileExists(atPath: handoff.path) {
                try fallbackHandoff.write(to: handoff, atomically: true, encoding: .utf8)
            }
            if let screenshot {
                try screenshot.write(to: previewURL(revision, designDirectory: designDirectory),
                                     options: .atomic)
            }
        } catch let failure as Failure {
            try? files.removeItem(at: revisionDirectory)
            throw failure
        } catch {
            try? files.removeItem(at: revisionDirectory)
            throw Failure.couldNotSave(error.localizedDescription)
        }
    }

    static func restore(_ revision: DesignRevision, in designDirectory: URL) throws {
        let files = FileManager.default
        let materials = materialsDirectory(revision, designDirectory: designDirectory)
        guard files.fileExists(atPath: materials.path) else { throw Failure.noDesign }
        do {
            for entry in try files.contentsOfDirectory(
                at: designDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) where !reservedLiveEntry(entry.lastPathComponent) {
                try files.removeItem(at: entry)
            }
            for entry in try files.contentsOfDirectory(
                at: materials,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                try files.copyItem(at: entry,
                                   to: designDirectory.appendingPathComponent(entry.lastPathComponent))
            }
        } catch {
            throw Failure.couldNotSave(error.localizedDescription)
        }
    }

    static func copyReference(_ revision: DesignRevision,
                              from designDirectory: URL,
                              to destination: URL) throws {
        let files = FileManager.default
        let source = materialsDirectory(revision, designDirectory: designDirectory)
        guard files.fileExists(atPath: source.path) else { throw Failure.noDesign }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("reference-copy-\(UUID().uuidString)", isDirectory: true)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent("reference-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: destination.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try files.copyItem(at: source, to: temporary)
            let preview = previewURL(revision, designDirectory: designDirectory)
            if files.fileExists(atPath: preview.path) {
                try files.copyItem(at: preview,
                                   to: temporary.appendingPathComponent("preview.png"))
            }
            if files.fileExists(atPath: destination.path) {
                try files.moveItem(at: destination, to: backup)
            }
            try files.moveItem(at: temporary, to: destination)
            try? files.removeItem(at: backup)
        } catch {
            try? files.removeItem(at: temporary)
            if files.fileExists(atPath: backup.path),
               !files.fileExists(atPath: destination.path) {
                try? files.moveItem(at: backup, to: destination)
            }
            throw Failure.couldNotSave(error.localizedDescription)
        }
    }

    private static func reservedLiveEntry(_ name: String) -> Bool {
        name == "revisions" || name == "reference"
    }
}
