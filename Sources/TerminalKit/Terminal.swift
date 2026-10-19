import Darwin
import Dispatch

// The tty itself: raw mode, the alternate screen, bracketed paste, and keys, resizes and
// signals delivered as events on the main queue, so a @MainActor run loop owns all of it.
// However the program ends (a quit, SIGINT, SIGTERM, SIGHUP, or a plain exit) the terminal
// is put back the way it was found.
@MainActor
public final class Terminal {
    public enum Event: Sendable, Equatable {
        case key(Key)
        case resize(TerminalSize)
        // SIGINT, SIGTERM or SIGHUP: the program is being asked to end. The terminal is
        // still in raw mode, so the handler quits through `stop()`.
        case signal(Int32)
        // Back from a suspend (Ctrl-Z then `fg`). Everything on screen is gone, so the
        // whole frame has to be painted again.
        case resumed
    }

    public private(set) var size = TerminalSize(cols: 80, rows: 24)
    public private(set) var isRunning = false

    private let input: Int32
    private let output: Int32
    private var original = termios()
    private var sources: [any DispatchSourceProtocol] = []
    private var reader: (any DispatchSourceRead)?
    // Lent to another program (see `lend()`), which reads the keys and draws meanwhile.
    private var lent = false
    private var decoder = KeyDecoder()
    private var onEvent: (@MainActor (Event) -> Void)?

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input
        self.output = output
    }

    // Whether there is a terminal to take over at all.
    nonisolated public static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    public func start(onEvent: @escaping @MainActor (Event) -> Void) {
        guard !isRunning else { return }
        self.onEvent = onEvent
        tcgetattr(input, &original)
        Self.saved = original
        Self.savedInput = input
        Self.savedOutput = output
        atexit { Terminal.restoreAtExit() }
        enter()
        isRunning = true

        for number in [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handle(signal: number) }
            }
            source.resume()
            sources.append(source)
        }

        let reader = DispatchSource.makeReadSource(fileDescriptor: input, queue: .main)
        reader.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readInput() }
        }
        reader.resume()
        sources.append(reader)
        self.reader = reader
    }

    // Puts the terminal back. Safe to call more than once.
    public func stop() {
        guard isRunning || lent else { return }
        if lent {
            // A suspended source must be resumed before it can be cancelled.
            reader?.resume()
            lent = false
        } else {
            leave()
        }
        isRunning = false
        sources.forEach { $0.cancel() }
        sources = []
        reader = nil
        for number in [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT] {
            signal(number, SIG_DFL)
        }
        onEvent = nil
    }

    // Ctrl-Z. Raw mode delivers it as a key rather than a signal, so the program asks
    // for the suspend itself. The terminal is handed back first, and `.resumed` follows
    // the `fg`.
    public func suspend() {
        guard isRunning else { return }
        handle(signal: SIGTSTP)
    }

    public func write(_ string: String) {
        Self.write(string, to: output)
    }

    // Hands the terminal to another program, such as `$EDITOR`: cooked mode and the main
    // screen are put back, and keys are left for that program to read. Until `takeBack()`
    // the terminal is not running, so nothing is drawn over the program, and Ctrl-C or
    // Ctrl-Z typed into it is that program's business.
    public func lend() {
        guard isRunning else { return }
        isRunning = false
        lent = true
        reader?.suspend()
        leave()
    }

    // Takes the terminal back from the program it was lent to. Whatever was on screen is
    // gone, so `.resumed` follows, for the whole frame to be painted again.
    public func takeBack() {
        guard lent else { return }
        lent = false
        enter()
        reader?.resume()
        isRunning = true
        onEvent?(.resumed)
    }

    // The terminal's own bell, which most terminals turn into a sound, a flash or a badge.
    public func bell() {
        write("\u{07}")
    }

    // A desktop notification through OSC 9, which iTerm2, Ghostty, kitty and WezTerm
    // show. Terminals without it ignore the sequence.
    public func notify(_ text: String) {
        let clean = text.filter { $0 != "\u{07}" && $0 != "\u{1B}" }
        write("\u{1B}]9;\(clean)\u{07}")
    }

    // MARK: - Modes

    private func enter() {
        var raw = original
        cfmakeraw(&raw)
        // Output processing stays on, so a stray print still starts a new line properly.
        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
        // TCSANOW rather than TCSAFLUSH: keys typed while the program started are kept.
        tcsetattr(input, TCSANOW, &raw)
        // Alternate screen, hidden cursor, bracketed paste.
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[2J")
        size = Self.querySize(output)
    }

    private func leave() {
        write(Self.restoreSequence)
        tcsetattr(input, TCSANOW, &original)
    }

    nonisolated private static let restoreSequence = "\u{1B}[0m\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l"

    // MARK: - Events

    private func handle(signal number: Int32) {
        if lent {
            // The program the terminal is lent to answers these. Only the size is kept
            // up to date, for the frame painted once the terminal comes back.
            if number == SIGWINCH { size = Self.querySize(output) }
            return
        }
        switch number {
        case SIGWINCH:
            size = Self.querySize(output)
            onEvent?(.resize(size))
        case SIGTSTP:
            // Hand the terminal back before stopping, as a shell expects. A signal sent
            // to itself stops the process before `kill` returns, so the line after it
            // runs on `fg`. A process group with no shell to resume it never stops at
            // all, and carries straight on, which is why nothing waits for SIGCONT.
            leave()
            signal(SIGTSTP, SIG_DFL)
            kill(getpid(), SIGTSTP)
            signal(SIGTSTP, SIG_IGN)
            enter()
            onEvent?(.resumed)
        case SIGCONT:
            // Continued after a stop that did not come through here (SIGSTOP). Taking
            // raw mode again is harmless if it was never lost.
            enter()
            onEvent?(.resumed)
        default:
            onEvent?(.signal(number))
        }
    }

    private func readInput() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(input, &buffer, buffer.count)
        guard count > 0 else { return }
        for key in decoder.feed(buffer[0..<count]) { onEvent?(.key(key)) }
        // A lone ESC might be the start of a sequence still on its way. If nothing
        // follows within 25 ms, it was the Escape key.
        if decoder.hasLoneEscape {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for key in self.decoder.flush() { self.onEvent?(.key(key)) }
                }
            }
        }
    }

    // MARK: - Low level

    nonisolated public static func querySize(_ fd: Int32 = STDOUT_FILENO) -> TerminalSize {
        var window = winsize()
        guard ioctl(fd, TIOCGWINSZ, &window) == 0, window.ws_col > 0 else {
            return TerminalSize(cols: 80, rows: 24)
        }
        return TerminalSize(cols: Int(window.ws_col), rows: Int(window.ws_row))
    }

    nonisolated private static func write(_ string: String, to fd: Int32) {
        var text = string
        text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return }
                offset += written
            }
        }
    }

    // What an exit that skipped `stop()` needs to put the terminal back. Set once, on the
    // main actor, before anything can exit.
    nonisolated(unsafe) private static var saved: termios?
    nonisolated(unsafe) private static var savedInput: Int32 = STDIN_FILENO
    nonisolated(unsafe) private static var savedOutput: Int32 = STDOUT_FILENO

    nonisolated private static func restoreAtExit() {
        guard var original = saved else { return }
        var current = termios()
        tcgetattr(savedInput, &current)
        // Already restored by `stop()`: nothing to undo, and no stray bytes to print.
        guard current.c_lflag != original.c_lflag else { return }
        write(restoreSequence, to: savedOutput)
        tcsetattr(savedInput, TCSANOW, &original)
    }
}
