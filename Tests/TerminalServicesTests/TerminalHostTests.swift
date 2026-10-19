import CodeStationCore
import Foundation
import Testing
import TerminalServices

// The terminal host, checked by the exact bytes it hands the terminal. The sink stands in
// for the tty, so nothing here needs one.
@MainActor
struct TerminalHostTests {
    private let bell = "\u{07}"
    private let id = UUID()

    private final class Sink {
        var written = ""
    }

    private func host(sound: SessionSound = .glass, environment: [String: String] = [:])
        -> (TerminalHost, Sink) {
        let sink = Sink()
        let host = TerminalHost(output: { sink.written += $0 }, environment: environment,
                                sound: { sound })
        return (host, sink)
    }

    // MARK: - Notifications

    // The runner asks for the sound, then reports the turn, as it does for the GUI.
    @Test func aFinishedTurnRingsTheBellThenPostsAnOSC9Notification() {
        let (host, sink) = host()

        host.playSessionSound()
        host.turnEnded(sessionID: id, sessionTitle: "Fix login", failure: nil)

        #expect(sink.written == "\u{07}" + "\u{1B}]9;Fix login: Finished and waiting for you.\u{07}")
    }

    // The sound setting decides the bell. The notification still goes, as the GUI's does.
    @Test func withTheSessionSoundOffTheBellStaysQuiet() {
        let (host, sink) = host(sound: .off)

        host.playSessionSound()
        host.turnEnded(sessionID: id, sessionTitle: "Fix login", failure: nil)

        #expect(sink.written == "\u{1B}]9;Fix login: Finished and waiting for you.\u{07}")
    }

    @Test func aFailedTurnSaysWhyOnItsFirstLine() {
        let (host, sink) = host()

        host.turnEnded(sessionID: id, sessionTitle: "Fix login", failure: "Rate limited\nretry later")

        #expect(sink.written == "\u{1B}]9;Fix login: The turn failed: Rate limited\u{07}")
    }

    @Test func aPermissionRequestRingsAndSaysWhatItIsAbout() {
        let (host, sink) = host()

        host.needsInput(sessionID: id, sessionTitle: "Fix login",
                        request: request(subject: "rm -rf build"))

        #expect(sink.written == "\u{07}" + "\u{1B}]9;Fix login: Waiting for permission: rm -rf build\u{07}")
    }

    @Test func aQuestionIsNamedByItsFirstQuestion() {
        let (host, sink) = host(sound: .off)

        host.needsInput(sessionID: id, sessionTitle: "Fix login",
                        request: request(subject: "", question: "Which database?"))

        #expect(sink.written == "\u{1B}]9;Fix login: Which database?\u{07}")
    }

    // An escape or a bell inside a title would end the sequence early and spill the rest
    // onto the screen.
    @Test func controlCharactersNeverReachTheNotification() {
        let (host, sink) = host()

        host.turnEnded(sessionID: id, sessionTitle: "Fix\u{1B}]0;x\u{07} login", failure: nil)

        #expect(sink.written == "\u{1B}]9;Fix]0;x login: Finished and waiting for you.\u{07}")
    }

    @Test func aStaleWaitRingsAndSaysWhatItIsWaitingFor() {
        let (host, sink) = host()
        let tasks = [AgentBackgroundTask(id: "a", kind: "local_bash", description: "Build"),
                     AgentBackgroundTask(id: "b", kind: "local_bash", description: "Serve")]

        host.waitWentStale(sessionID: id, sessionTitle: "Fix login", tasks: tasks)

        #expect(sink.written == "\u{07}" + "\u{1B}]9;Fix login: Still waiting for 2 background tasks. "
            + "The turn is held open and needs you.\u{07}")
    }

    // MARK: - Clipboard

    // OSC 52 travels inside the terminal's own stream, so it reaches the clipboard of
    // the Mac in front of the person even over SSH.
    @Test func copiedTextGoesToTheClipboardThroughOSC52() {
        let (host, sink) = host()

        host.copy(.text("héllo"))

        #expect(sink.written == "\u{1B}]52;c;aMOpbGxv\u{07}")
    }

    @Test func aCopiedFileTravelsAsItsPath() {
        let (host, sink) = host()

        host.copy(.file(URL(fileURLWithPath: "/tmp/a b.txt")))

        #expect(sink.written == "\u{1B}]52;c;L3RtcC9hIGIudHh0\u{07}")
    }

    // A terminal clipboard holds text, so a picture is copied as the file it came from,
    // and one with no file copies nothing.
    @Test func anImageTravelsAsItsFileOrNotAtAll() {
        let (host, sink) = host()

        host.copy(.image(png: Data([1, 2, 3]), file: nil))
        #expect(sink.written == "")

        host.copy(.image(png: Data([1, 2, 3]), file: URL(fileURLWithPath: "/tmp/a b.txt")))
        #expect(sink.written == "\u{1B}]52;c;L3RtcC9hIGIudHh0\u{07}")
    }

    // Inside tmux the sequence goes twice: wrapped in tmux's passthrough, which reaches
    // the outer terminal when `allow-passthrough` is on, and bare, which tmux takes
    // itself when `set-clipboard` is on. Either way the clipboard ends up the same.
    @Test func insideTmuxTheClipboardSequenceIsAlsoPassedThrough() {
        let (host, sink) = host(environment: ["TMUX": "/private/tmp/tmux-502/default,1,0"])

        host.copy(.text("say \"hi\"\n"))

        let osc52 = "\u{1B}]52;c;c2F5ICJoaSIK\u{07}"
        #expect(sink.written == "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;c2F5ICJoaSIK\u{07}\u{1B}\\" + osc52)
    }

    // tmux has no use for OSC 9 itself, so only the outer terminal is told. The bell is
    // tmux's own to pass on.
    @Test func insideTmuxANotificationIsPassedThroughToTheOuterTerminal() {
        let (host, sink) = host(environment: ["TMUX": "/private/tmp/tmux-502/default,1,0"])

        host.playSessionSound()
        host.turnEnded(sessionID: id, sessionTitle: "Fix login", failure: nil)

        #expect(sink.written == "\u{07}"
            + "\u{1B}Ptmux;\u{1B}\u{1B}]9;Fix login: Finished and waiting for you.\u{07}\u{1B}\\")
    }

    // MARK: - Open in

    @Test func aPathOpensInTheChosenAppThroughOpen() {
        var launched: [[String]] = []
        let host = TerminalHost(output: { _ in }, environment: [:], sound: { .glass },
                                launch: { launched.append($0) }, locate: { _ in nil })
        let zed = OpenInApp(bundleID: "dev.zed.Zed", name: "Zed",
                            url: URL(fileURLWithPath: "/Applications/Zed.app"))

        host.open(URL(fileURLWithPath: "/tmp/my repo"), in: zed)

        #expect(launched == [["/usr/bin/open", "-b", "dev.zed.Zed", "/tmp/my repo"]])
    }

    // The installed editors, then Finder, then the terminal the TUI runs in, as the GUI
    // orders them. Apps that are not installed are left out.
    @Test func theAppsOnOfferAreTheInstalledEditorsFinderAndThisTerminal() {
        let installed = [
            "dev.zed.Zed": "/Applications/Zed.app",
            "com.microsoft.VSCode": "/Applications/Visual Studio Code.app",
            "com.apple.finder": "/System/Library/CoreServices/Finder.app",
            "com.googlecode.iterm2": "/Applications/iTerm.app",
        ]
        let host = TerminalHost(output: { _ in }, environment: ["TERM_PROGRAM": "iTerm.app"],
                                sound: { .glass }, launch: { _ in },
                                locate: { installed[$0].map { URL(fileURLWithPath: $0) } })

        let apps = host.openInApps()

        #expect(apps.map(\.bundleID) == ["com.microsoft.VSCode", "dev.zed.Zed", "com.apple.finder",
                                         "com.googlecode.iterm2"])
        #expect(apps.map(\.name) == ["Visual Studio Code", "Zed", "Finder", "iTerm"])
    }

    // MARK: - Choosing a folder

    @Test func aTypedFolderIsTheChosenDirectory() async throws {
        let root = try temporaryFolder()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"),
                                                withIntermediateDirectories: true)
        let (host, _) = host()
        var asked: [String] = []
        host.askForPath = { prompt, message, start in
            asked = [prompt, message, start?.path ?? ""]
            return "app/"
        }

        let chosen = try await host.chooseDirectory(prompt: "Add", message: "Pick a project folder",
                                                    startingAt: root)

        #expect(asked == ["Add", "Pick a project folder", root.path])
        #expect(chosen?.standardizedFileURL.path == root.appendingPathComponent("app").standardizedFileURL.path)
    }

    @Test func aTildeStandsForTheHomeFolder() async throws {
        let (host, _) = host()
        host.askForPath = { _, _, _ in "~" }

        let chosen = try await host.chooseDirectory(prompt: "", message: "", startingAt: nil)

        #expect(chosen?.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }

    @Test func nothingTypedIsACancel() async throws {
        let (host, _) = host()
        host.askForPath = { _, _, _ in "   " }
        #expect(try await host.chooseDirectory(prompt: "", message: "", startingAt: nil) == nil)

        host.askForPath = { _, _, _ in nil }
        #expect(try await host.chooseDirectory(prompt: "", message: "", startingAt: nil) == nil)
    }

    @Test func aTypedPathThatIsNotAFolderIsRefused() async throws {
        let root = try temporaryFolder()
        let file = root.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let (host, _) = host()
        host.askForPath = { _, _, _ in file.path }

        await #expect(throws: TerminalHost.NotAFolder(path: file.path)) {
            try await host.chooseDirectory(prompt: "", message: "", startingAt: nil)
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func request(subject: String, question: String? = nil) -> PermissionRequest {
        PermissionRequest(
            id: "req", toolName: "Bash", title: "Run", subject: subject, detail: "",
            input: Data(), suggestions: nil, alwaysTitle: nil,
            questions: question.map {
                [AgentQuestion(id: 0, header: "", text: $0, multiSelect: false, options: [])]
            } ?? [])
    }
}
