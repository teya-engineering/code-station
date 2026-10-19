import CodeStationCore
import CoreServices
import Foundation

// What the core reaches the OS through when it runs in a terminal:
// - a turn that ends, a question and a stale wait post an OSC 9 notification, and ring
//   the bell unless the session sound is off;
// - copying writes OSC 52, which reaches the clipboard of the Mac in front of the person
//   even over SSH, and is passed through tmux;
// - "open in" runs `/usr/bin/open -b <app> <path>`, and a web link `/usr/bin/open <url>`;
// - a folder is a typed path, asked for through `askForPath`, which the TUI answers with
//   a line to type in.
// Every byte goes through `output`, and every launch through `launch`, so tests read
// exactly what the host did.
@MainActor
public final class TerminalHost: HostServices {
    private let output: @MainActor (String) -> Void
    private let sound: @MainActor () -> SessionSound
    // Inside tmux, sequences tmux does not act on itself are passed through to the
    // terminal it runs in.
    private let insideTmux: Bool
    private let terminalProgram: String?
    private let launch: @MainActor ([String]) -> Void
    private let locate: @MainActor (String) -> URL?

    // Asks the person to type a folder: the prompt, a line saying what it is for, and
    // where a relative path starts. Nil when they cancel. With no one to ask, choosing a
    // folder is always cancelled.
    public var askForPath: (@MainActor (_ prompt: String, _ message: String,
                                        _ startingAt: URL?) async -> String?)?

    // A typed path that is not a folder.
    public struct NotAFolder: Error, Equatable, CustomStringConvertible {
        public let path: String
        public init(path: String) { self.path = path }
        public var description: String { "\(path) is not a folder." }
    }

    public init(output: @escaping @MainActor (String) -> Void,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                sound: @escaping @MainActor () -> SessionSound = { Preferences.sessionFinishedSound() },
                launch: @escaping @MainActor ([String]) -> Void = TerminalHost.run,
                locate: @escaping @MainActor (String) -> URL? = TerminalHost.installedApp) {
        self.output = output
        self.sound = sound
        self.launch = launch
        self.locate = locate
        insideTmux = !(environment["TMUX"] ?? "").isEmpty
        terminalProgram = environment["TERM_PROGRAM"]
    }

    public func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {
        notify(sessionTitle, failure.map { "The turn failed: \(Self.firstLine($0))" }
            ?? "Finished and waiting for you.")
    }

    // The GUI's notification for this one has a sound of its own, so it rings even when
    // the turn is still running; the session sound setting still silences it.
    public func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {
        let body = request.isQuestion
            ? (request.questions.first?.text ?? "The agent has a question for you.")
            : "Waiting for permission: \(request.subject.isEmpty ? request.toolName : request.subject)"
        playSessionSound()
        notify(sessionTitle, Self.firstLine(body))
    }
    public func waitWentStale(sessionID: UUID, sessionTitle: String, tasks: [AgentBackgroundTask]) {
        playSessionSound()
        notify(sessionTitle, "Still waiting for \(BackgroundTaskPhrase.of(tasks)). "
            + "The turn is held open and needs you.")
    }

    // A notification sent through the terminal cannot be taken back.
    public func clear(sessionID: UUID) {}

    public func playSessionSound() {
        guard sound() != .off else { return }
        output(TerminalEscape.bell)
    }

    // A terminal's clipboard holds text, so a file goes as its path and a picture as the
    // file it came from. A picture with no file has nothing to send.
    public func copy(_ content: ClipboardContent) {
        let text: String
        switch content {
        case .text(let string): text = string
        case .file(let url): text = url.path
        case .image(_, let file?): text = file.path
        case .image(_, nil): return
        }
        let sequence = TerminalEscape.clipboard(text)
        // Twice inside tmux: passed through for a tmux with `allow-passthrough`, and bare
        // for one with `set-clipboard on`, which sets the outer clipboard itself. Either
        // way the clipboard ends up holding the same text.
        if insideTmux { output(TerminalEscape.tmuxPassthrough(sequence)) }
        output(sequence)
    }

    // MARK: - Open in

    public func openInApps() -> [OpenInApp] {
        let terminalID = terminalProgram.flatMap { Self.terminalIDs[$0] }
        return OpenIn.ordered(editors: OpenIn.editorIDs.compactMap(app),
                              finder: app(OpenIn.finderID),
                              terminal: terminalID.flatMap(app))
    }

    public func open(_ path: URL, in app: OpenInApp) {
        launch(["/usr/bin/open", "-b", app.bundleID, path.path])
    }

    // Only a web link: `open` would otherwise run an app or a file it names.
    // A web page, or a page on this machine such as a Design's canvas: an HTML file that
    // is there. Anything else is not opened.
    public func openLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "https", "http": break
        case "file":
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path) else { return }
        default: return
        }
        launch(["/usr/bin/open", url.absoluteString])
    }

    private func app(_ bundleID: String) -> OpenInApp? {
        locate(bundleID).map {
            OpenInApp(bundleID: bundleID, name: $0.deletingPathExtension().lastPathComponent, url: $0)
        }
    }

    // What TERM_PROGRAM says, as the app it names.
    private static let terminalIDs = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode",
    ]

    // Launch Services' answer, from CoreServices rather than AppKit.
    public static func installedApp(_ bundleID: String) -> URL? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
            .takeRetainedValue() as? [URL] else { return nil }
        return urls.first
    }

    // Runs a command and lets it go: `open` returns as soon as the app has the path.
    public static func run(_ arguments: [String]) {
        guard let executable = arguments.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Choosing a folder

    // A typed path in place of an open panel. `~` is the home folder, and a relative path
    // starts where the picker would have opened.
    public func chooseDirectory(prompt: String, message: String,
                                startingAt directory: URL?) async throws -> URL? {
        guard let askForPath,
              let typed = await askForPath(prompt, message, directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.isEmpty else { return nil }
        let expanded = (typed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") || directory == nil
            ? URL(fileURLWithPath: expanded)
            : directory!.appendingPathComponent(expanded)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw NotAFolder(path: url.standardizedFileURL.path)
        }
        return url.standardizedFileURL
    }

    // MARK: - Writing

    private func notify(_ title: String, _ body: String) {
        let sequence = TerminalEscape.notification("\(title): \(body)")
        output(insideTmux ? TerminalEscape.tmuxPassthrough(sequence) : sequence)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
