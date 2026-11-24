import AppKit
import Foundation
import Observation
import SwiftTerm

// One shell tab: a pty, the SwiftTerm surface that emulates and draws it, and the
// little bit of state the tab strip shows. Terminals are owned by TerminalStore and
// outlive switching tabs, so a build keeps running while you are reading the chat.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let directory: String

    private(set) var isRunning = false
    private(set) var failure: String?
    // True while a command holds the terminal, so a tab that is building in the
    // background says so.
    private(set) var isBusy = false
    // Tabs start numbered and can be renamed, so a shell kept for one job can say what
    // that job is.
    var name: String

    // The surface is the emulator and the screen in one, so it holds the scrollback.
    // It lives with the session rather than the drawer, which is what lets the screen
    // survive tab switches and the drawer being put away.
    @ObservationIgnored let surface: TerminalSurface
    @ObservationIgnored private var pty: PTY?
    @ObservationIgnored private var output: TerminalOutputBuffer?
    @ObservationIgnored private var busyPoll: Task<Void, Never>?
    @ObservationIgnored private var busyMonitoringEnabled = true
    @ObservationIgnored private let registry: ShellRegistry
    @ObservationIgnored private let onExit: ((TerminalSession) -> Void)?

    private static let shell: String = {
        // The login shell is what the user actually configured; fall back to zsh, the
        // macOS default, when the environment does not say.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }()

    init(directory: String, name: String, registry: ShellRegistry = .shared,
         scrollback: Int = Preferences.terminalScrollback.read(),
         onExit: ((TerminalSession) -> Void)? = nil) {
        self.directory = directory
        self.name = name
        self.registry = registry
        self.onExit = onExit
        surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        surface.setScrollback(scrollback)
        surface.terminalDelegate = self
        surface.onClear = { [weak self] in self?.clear() }
    }

    // MARK: - Lifecycle

    func start() {
        guard pty == nil else { return }

        let output = TerminalOutputBuffer()
        self.output = output
        let terminal = PTY(
            registry: registry,
            onOutput: { [weak self] data in
                guard output.append(data) else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self else {
                        output.close()
                        return
                    }
                    self.flush(output)
                }
            },
            onExit: { [weak self] _ in
                Task { @MainActor in self?.shellExited(output) }
            })
        pty = terminal

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "TeyaCodeStation"
        environment["PATH"] = ProcessManager.searchPath
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"

        do {
            let screen = surface.terminalDimensions
            // -i so the shell reads the user's rc files and behaves like their terminal.
            try terminal.start(shell: Self.shell, arguments: ["-i"], directory: directory,
                               environment: environment,
                               columns: screen.cols, rows: screen.rows)
            isRunning = true
            failure = nil
            if busyMonitoringEnabled { watchForCommands() }
        } catch {
            output.close()
            self.output = nil
            pty = nil
            failure = error.localizedDescription
        }
    }

    func stop() {
        busyPoll?.cancel()
        busyPoll = nil
        output?.close()
        output = nil
        pty?.stop()
        pty = nil
        isRunning = false
        isBusy = false
    }

    // Process sampling happens away from the main actor. Idle tabs are checked less
    // often than running commands, while hidden drawers stop checking altogether.
    private func watchForCommands() {
        busyPoll?.cancel()
        guard let pty else { return }
        busyPoll = Task.detached { [weak self, pty] in
            while !Task.isCancelled {
                let busy = pty.sampleBusy()
                guard !Task.isCancelled else { return }
                let active = await MainActor.run {
                    guard let self, self.pty === pty, self.busyMonitoringEnabled else {
                        return false
                    }
                    if busy != self.isBusy { self.isBusy = busy }
                    return true
                }
                guard active else { return }
                try? await Task.sleep(for: busy ? .milliseconds(500) : .seconds(1))
            }
        }
    }

    func setBusyMonitoring(_ enabled: Bool) {
        guard busyMonitoringEnabled != enabled else { return }
        busyMonitoringEnabled = enabled
        if enabled, isRunning {
            watchForCommands()
        } else {
            busyPoll?.cancel()
            busyPoll = nil
            isBusy = false
        }
    }

    // MARK: - Input

    func send(_ text: String) {
        pty?.write(Data(text.utf8))
    }

    // A command put at the prompt for the user to look at, edit and run themselves;
    // nothing is run here. Bracketed paste is what stops a command that spans several
    // lines from running all but its last line as it arrives. A shell turns it on once
    // its line editor is ready and off again while a command holds the terminal, so it
    // doubles as the shell saying it is at a prompt and can take this - a shell that
    // has only just started needs a moment to get there.
    func paste(_ text: String) {
        guard !text.isEmpty, isRunning else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2)
            while surface.terminalInputStateSnapshot()?.bracketedPasteMode != true,
                  isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard isRunning else { return }
            if surface.terminalInputStateSnapshot()?.bracketedPasteMode == true {
                send("\u{1b}[200~\(text)\u{1b}[201~")
            } else {
                // Older line editors use Control-V to insert control characters literally.
                // Sending a bare newline would run part of the command before Enter.
                let quoted = text.unicodeScalars.map { scalar in
                    scalar.value < 32 || scalar.value == 127 ? "\u{16}\(scalar)" : String(scalar)
                }.joined()
                send(quoted)
            }
        }
    }

    func clear() {
        surface.resetToInitialState()
        surface.setNeedsDisplay(surface.bounds)
    }

    // What the screen currently shows; read by tests.
    func screenText() -> String {
        let data = surface.getBufferAsData()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Output
    //
    // Only one bounded batch waits for the main actor. A busy shell waits for the
    // screen to catch up instead of creating a task and retaining bytes on every read.
    private func flush(_ output: TerminalOutputBuffer) {
        guard self.output === output else { return }
        let data = output.drain()
        guard !data.isEmpty else { return }
        surface.feed(byteArray: ArraySlice([UInt8](data)))
    }

    private func shellExited(_ output: TerminalOutputBuffer) {
        guard self.output === output else { return }
        flush(output)
        output.close()
        self.output = nil
        busyPoll?.cancel()
        busyPoll = nil
        isRunning = false
        isBusy = false
        pty = nil
        onExit?(self)
    }
}

final class TerminalOutputBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var pending = Data()
    private var closed = false

    init(capacity: Int = 256 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    // Called only from the PTY's read queue. Blocking here lets the kernel's terminal
    // buffer slow the writer without blocking the UI or discarding escape sequences.
    func append(_ data: Data) -> Bool {
        precondition(data.count <= capacity)
        condition.lock()
        defer { condition.unlock() }
        while !closed, pending.count + data.count > capacity { condition.wait() }
        guard !closed, !data.isEmpty else { return false }
        let needsFlush = pending.isEmpty
        pending.append(data)
        return needsFlush
    }

    func drain() -> Data {
        condition.lock()
        defer { condition.unlock() }
        let data = pending
        pending = Data()
        condition.broadcast()
        return data
    }

    func close() {
        condition.lock()
        defer { condition.unlock() }
        closed = true
        pending = Data()
        condition.broadcast()
    }
}

// The surface calls back on the main thread, which is where the session lives.
extension TerminalSession: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pty?.write(Data(data))
    }

    // The surface works out its own columns and rows from its frame; the shell just
    // has to be told, or anything that draws a full line wraps in the wrong place.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        pty?.resize(columns: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
