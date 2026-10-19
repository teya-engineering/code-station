import TerminalKit

// A terminal with no tty behind it. What the TUI writes goes through a virtual screen, and
// keys, sizes and signals are handed to the TUI exactly as the real terminal hands them
// over, on the main actor.
@MainActor
final class FakeTerminal: TerminalDevice {
    private(set) var size: TerminalSize
    private(set) var isRunning = false
    private(set) var screen: VirtualScreen
    // Every byte written, for a test that wants the raw output (OSC 9, OSC 52, the bell).
    private(set) var output = ""
    private(set) var suspends = 0
    private var onEvent: (@MainActor (Terminal.Event) -> Void)?

    init(size: TerminalSize) {
        self.size = size
        screen = VirtualScreen(cols: size.cols, rows: size.rows)
    }

    func start(onEvent: @escaping @MainActor (Terminal.Event) -> Void) {
        guard !isRunning else { return }
        self.onEvent = onEvent
        isRunning = true
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[2J")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        write("\u{1B}[0m\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l")
        onEvent = nil
    }

    func suspend() {
        guard isRunning else { return }
        suspends += 1
        send(.resumed)
    }

    func write(_ string: String) {
        output += string
        screen.feed(string)
    }

    // MARK: - Driving

    func send(_ event: Terminal.Event) {
        onEvent?(event)
    }

    func resize(to size: TerminalSize) {
        self.size = size
        screen.resize(cols: size.cols, rows: size.rows)
        send(.resize(size))
    }
}
