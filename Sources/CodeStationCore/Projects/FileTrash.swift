import Foundation

// How a file is put in the Trash, so a slip can be undone from Finder. Tests hand over
// one of their own, so a run leaves nothing in the person's real Trash.
public struct FileTrash: Sendable {
    public let move: @Sendable (URL) throws -> Void

    public init(_ move: @escaping @Sendable (URL) throws -> Void) {
        self.move = move
    }

    public static let system = FileTrash { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}
