import Foundation

enum PersistentFile {
    static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func loadMessage(for url: URL, error: Error) -> String {
        "The file at \(url.path) could not be loaded: \(error.localizedDescription)"
    }

    static func decodeMessage(for url: URL, error: Error) -> String {
        "The file at \(url.path) could not be parsed: \(error.localizedDescription)"
    }

    static func saveMessage(for url: URL, error: Error) -> String {
        "The file at \(url.path) could not be saved: \(error.localizedDescription)"
    }
}

struct PersistentFileClient: Sendable {
    var readIfPresent: @Sendable (URL) throws -> Data?
    var write: @Sendable (Data, URL) throws -> Void
    var removeIfPresent: @Sendable (URL) throws -> Void

    static let live = PersistentFileClient(
        readIfPresent: { try PersistentFile.readIfPresent($0) },
        write: { try PersistentFile.write($0, to: $1) },
        removeIfPresent: { try PersistentFile.removeIfPresent($0) }
    )
}
