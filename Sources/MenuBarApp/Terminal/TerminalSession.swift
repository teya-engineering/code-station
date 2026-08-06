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
    @ObservationIgnored private var incoming = Data()
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var busyPoll: Task<Void, Never>?

    private static let shell: String = {
        // The login shell is what the user actually configured; fall back to zsh, the
        // macOS default, when the environment does not say.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }()

    init(directory: String, name: String) {
        self.directory = directory
        self.name = name
        surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        surface.terminalDelegate = self
        surface.onClear = { [weak self] in self?.clear() }
    }

    // MARK: - Lifecycle

    func start() {
        guard pty == nil else { return }

        let session = self
        let terminal = PTY(
            onOutput: { data in
                Task { @MainActor in session.receive(data) }
            },
            onExit: { _ in
                Task { @MainActor in session.shellExited() }
            })
        pty = terminal

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "TeyaConductor"
        environment["PATH"] = ProcessManager.searchPath
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"

        do {
            let screen = surface.getTerminal()
            // -i so the shell reads the user's rc files and behaves like their terminal.
            try terminal.start(shell: Self.shell, arguments: ["-i"], directory: directory,
                               environment: environment,
                               columns: screen.cols, rows: screen.rows)
            isRunning = true
            failure = nil
            watchForCommands()
        } catch {
            pty = nil
            failure = error.localizedDescription
        }
    }

    func stop() {
        busyPoll?.cancel()
        busyPoll = nil
        pty?.stop()
        pty = nil
        isRunning = false
        isBusy = false
    }

    // There is nothing to be notified about here, so the shell's children are polled
    // slowly enough to be free and often enough to feel live.
    private func watchForCommands() {
        busyPoll?.cancel()
        busyPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pty = self.pty else { return }
                let busy = pty.sampleBusy()
                if busy != self.isBusy { self.isBusy = busy }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // MARK: - Input

    func send(_ text: String) {
        pty?.write(Data(text.utf8))
    }

    func clear() {
        surface.getTerminal().resetToInitialState()
        surface.setNeedsDisplay(surface.bounds)
    }

    // What the screen currently shows; read by tests.
    func screenText() -> String {
        let data = surface.getTerminal().getBufferAsData()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Output
    //
    // A build can print faster than the screen can be redrawn, so chunks are gathered
    // and fed once per frame instead of once per read.

    private func receive(_ data: Data) {
        incoming.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !incoming.isEmpty else { return }
        let data = incoming
        incoming = Data()
        surface.feed(byteArray: ArraySlice([UInt8](data)))
    }

    private func shellExited() {
        flush()
        busyPoll?.cancel()
        busyPoll = nil
        isRunning = false
        isBusy = false
        pty = nil
    }
}

// The surface calls back on the main thread, which is where the session lives.
extension TerminalSession: @preconcurrency TerminalViewDelegate {
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

// The terminals belonging to each chat session, plus how the drawer is sitting.
// Keeping them here, rather than in the view, is what lets a shell keep running while
// the drawer is collapsed or another session is on screen.
@MainActor
@Observable
final class TerminalStore {
    static let minimumHeight: CGFloat = 120
    static let defaultHeight: CGFloat = 300

    private var terminals: [UUID: [TerminalSession]] = [:]
    private var selected: [UUID: UUID] = [:]
    private var open: Set<UUID> = []
    private var heights: [UUID: CGFloat] = [:]

    func sessions(for sessionID: UUID) -> [TerminalSession] { terminals[sessionID] ?? [] }

    func selection(for sessionID: UUID) -> TerminalSession? {
        let all = sessions(for: sessionID)
        if let id = selected[sessionID], let match = all.first(where: { $0.id == id }) { return match }
        return all.first
    }

    func select(_ terminal: TerminalSession, in sessionID: UUID) {
        selected[sessionID] = terminal.id
    }

    // MARK: - Drawer

    // Shut by default, and it takes nothing from the chat while it is: a session opens
    // on the conversation, and the terminal appears only when it is asked for.
    func isOpen(_ sessionID: UUID) -> Bool { open.contains(sessionID) }

    func setOpen(_ isOpen: Bool, for sessionID: UUID, directory: String) {
        if isOpen {
            ensureOne(for: sessionID, directory: directory)
            open.insert(sessionID)
        } else {
            open.remove(sessionID)
        }
    }

    func height(for sessionID: UUID) -> CGFloat { heights[sessionID] ?? Self.defaultHeight }

    func setHeight(_ height: CGFloat, for sessionID: UUID) {
        heights[sessionID] = max(Self.minimumHeight, height)
    }

    // MARK: - Tabs

    // The first terminal for a session is made on demand, so no shell is started for a
    // session whose drawer is never opened.
    @discardableResult
    func add(to sessionID: UUID, directory: String) -> TerminalSession {
        let terminal = TerminalSession(directory: directory,
                                       name: nextName(in: sessionID))
        terminal.start()
        terminals[sessionID, default: []].append(terminal)
        selected[sessionID] = terminal.id
        return terminal
    }

    // "Terminal", then "Terminal 2"; renamed tabs are skipped over rather than counted,
    // so closing one does not produce a duplicate name.
    private func nextName(in sessionID: UUID) -> String {
        let taken = Set(sessions(for: sessionID).map(\.name))
        if !taken.contains("Terminal") { return "Terminal" }
        var number = 2
        while taken.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

    func ensureOne(for sessionID: UUID, directory: String) {
        guard sessions(for: sessionID).isEmpty else { return }
        add(to: sessionID, directory: directory)
    }

    func close(_ terminal: TerminalSession, in sessionID: UUID) {
        terminal.stop()
        terminals[sessionID]?.removeAll { $0.id == terminal.id }
        if selected[sessionID] == terminal.id {
            selected[sessionID] = terminals[sessionID]?.first?.id
        }
    }

    func stopEverything() {
        for terminal in terminals.values.flatMap({ $0 }) { terminal.stop() }
        terminals = [:]
        selected = [:]
    }
}
