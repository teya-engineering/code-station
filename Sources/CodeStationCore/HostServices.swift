import Foundation
import ImageIO
import UniformTypeIdentifiers

// Everything the core needs from the OS it runs on, handed to it at startup. The GUI
// answers with notifications, the pasteboard, NSSound, Launch Services and an open
// panel; a terminal host answers with a bell or OSC 9, OSC 52, `open` and a typed path.
// Nothing in the core reaches for a global singleton of its own, so no AppKit type
// appears here.
@MainActor
public protocol HostServices: AnyObject {
    // How the runner reaches someone who is not watching a session: a turn that ended,
    // a question that is waiting, a wait that went stale, and taking those back once the
    // session is opened. The runner names the user-facing session, so a Design
    // companion's turn is reported against the session that shows it.
    func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?)
    func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest)
    func waitWentStale(sessionID: UUID, sessionTitle: String, tasks: [AgentBackgroundTask])
    func clear(sessionID: UUID)

    // The sound a session makes when its turn ends. Called just before `turnEnded`; the
    // host decides whether to play it, and when.
    func playSessionSound()

    // Replaces the clipboard's contents.
    func copy(_ content: ClipboardContent)

    // The apps a path can be opened in: the installed editors, Finder and the terminal,
    // in the order `OpenIn.ordered` gives.
    func openInApps() -> [OpenInApp]
    // Opens a folder or file in one of `openInApps()`.
    func open(_ path: URL, in app: OpenInApp)
    // Opens a web link, such as a pull request, in the person's browser.
    func openLink(_ url: URL)

    // Asks the person for a folder. Nil when they cancel; a host that takes a typed path
    // throws when what was typed is not a folder.
    func chooseDirectory(prompt: String, message: String,
                         startingAt directory: URL?) async throws -> URL?
}

// What goes on the clipboard. An image travels as PNG bytes, the format apps take a
// picture off the clipboard in, along with the file it came from when there is one.
public enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case file(URL)
    case image(png: Data, file: URL?)
}

// An app a path can be opened in.
public struct OpenInApp: Equatable, Identifiable, Sendable {
    public let bundleID: String
    public let name: String
    public let url: URL

    public var id: String { bundleID }

    public init(bundleID: String, name: String, url: URL) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
    }
}

// For a host with nobody to tell, and for tests that do not listen.
@MainActor
public final class SilentHost: HostServices {
    public init() {}
    public func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {}
    public func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {}
    public func waitWentStale(sessionID: UUID, sessionTitle: String,
                              tasks: [AgentBackgroundTask]) {}
    public func clear(sessionID: UUID) {}
    public func playSessionSound() {}
    public func copy(_ content: ClipboardContent) {}
    public func openInApps() -> [OpenInApp] { [] }
    public func open(_ path: URL, in app: OpenInApp) {}
    public func openLink(_ url: URL) {}
    public func chooseDirectory(prompt: String, message: String,
                                startingAt directory: URL?) async throws -> URL? { nil }
}

extension ClipboardContent {
    // An image file as both the picture and the file it came from, so an app that takes
    // pixels and one that takes a file each find what they want. Nil when the file is
    // not an image ImageIO can read.
    public static func image(at file: URL) -> ClipboardContent? {
        guard let png = PNGEncoding.png(ofImageAt: file) else { return nil }
        return .image(png: png, file: file)
    }
}

// Apps take a picture off the clipboard as PNG, so a file saved in anything else is
// re-encoded. The bytes are read from disk rather than from what is drawn, which is only
// a reduced copy.
public enum PNGEncoding {
    public static func png(ofImageAt file: URL) -> Data? {
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.pathExtension)
        if type == .png { return try? Data(contentsOf: file) }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        // From the source rather than the decoded image, so its resolution comes along and
        // the picture keeps its size in points.
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
