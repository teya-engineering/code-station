import Foundation
import UniformTypeIdentifiers

// A file that goes out with a prompt. Claude Code takes files by path, so anything that
// arrives as raw bytes - a screenshot on the clipboard - has to be written to disk
// before the turn can start.
public struct Attachment: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let url: URL

    public var name: String { url.lastPathComponent }

    public var isImage: Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    public init(url: URL) {
        self.url = url
    }
}
