// What a front end needs from the terminal it draws on: its size, its events, and a way to
// write bytes to it. `Terminal` is the real tty; a test hands in one with no tty behind it
// and reads back what was drawn.
@MainActor
public protocol TerminalDevice: AnyObject {
    var size: TerminalSize { get }
    var isRunning: Bool { get }
    func start(onEvent: @escaping @MainActor (Terminal.Event) -> Void)
    // Puts the terminal back. Safe to call more than once.
    func stop()
    // Ctrl-Z: hands the terminal back to the shell, with `.resumed` after the `fg`.
    func suspend()
    func write(_ string: String)
}

extension Terminal: TerminalDevice {}
