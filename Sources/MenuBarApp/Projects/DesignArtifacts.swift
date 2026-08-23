import AppKit
import Foundation

enum DesignPhase: String, Codable, Equatable, Sendable {
    case designing
    case implementing
}

struct DesignScreen: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let path: String
    var width: Int?
    var height: Int?

    static let canvas = DesignScreen(id: "canvas", title: "Canvas", path: "index.html")
}

struct DesignManifest: Codable, Equatable, Sendable {
    var screens: [DesignScreen]

    static let singleScreen = DesignManifest(screens: [.canvas])

    static func read(from directory: URL) -> DesignManifest {
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

    static func safeURL(for screen: DesignScreen, in directory: URL) -> URL? {
        let root = directory.standardizedFileURL
        let candidate = root.appendingPathComponent(screen.path).standardizedFileURL
        guard candidate.path.pathRelative(to: root.path) != nil,
              candidate.pathExtension.lowercased() == "html",
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

struct DesignRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let sourceRevisions: [String: String]
    let screens: [DesignScreen]

    var title: String { "Design v\(number)" }
}

struct DesignArtifactRevision: Equatable, Sendable {
    struct FileRevision: Equatable, Sendable {
        let path: String
        let modified: Date
        let size: Int
    }

    let files: [FileRevision]

    static func read(_ directory: URL) -> DesignArtifactRevision? {
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

enum DesignArtifacts {
    enum Failure: LocalizedError, Equatable {
        case noDesign
        case couldNotSave(String)

        var errorDescription: String? {
            switch self {
            case .noDesign:
                "There is no Design to hand over yet."
            case .couldNotSave(let detail):
                "The Design revision could not be saved: \(detail)"
            }
        }
    }

    static func revisionDirectory(_ revision: DesignRevision,
                                  designDirectory: URL) -> URL {
        designDirectory
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revision.id.uuidString, isDirectory: true)
    }

    static func materialsDirectory(_ revision: DesignRevision,
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

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func reservedLiveEntry(_ name: String) -> Bool {
        name == "revisions" || name == "reference" || name == "implementation.png"
    }
}
