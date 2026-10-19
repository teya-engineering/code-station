import Darwin
import Foundation
import TerminalKit

// A program the TUI hands the terminal to and waits for: `$EDITOR` on a file, `$PAGER` on
// a log, `$SHELL` in a checkout. It runs on the client's terminal, in the folder given,
// and the TUI paints its frame again once the program exits.
struct Handoff: Equatable, Sendable {
    // The program and its arguments. The first is looked up on PATH.
    var arguments: [String]
    // Where it runs. Nil keeps the TUI's own working folder.
    var directory: String?
}

// Runs a handoff and says how it ended. Tests stand in a fake that records what was asked.
@MainActor
protocol HandoffRunner: AnyObject {
    // The program's exit status, or -1 when it could not be started.
    func run(_ handoff: Handoff) async -> Int32
}

// The real runner: lends the tty to the program and takes it back when the program exits.
@MainActor
final class TerminalHandoffRunner: HandoffRunner {
    private let terminal: Terminal

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func run(_ handoff: Handoff) async -> Int32 {
        guard !handoff.arguments.isEmpty else { return -1 }
        terminal.lend()
        let status = await Task.detached { Self.spawnAndWait(handoff) }.value
        terminal.takeBack()
        return status
    }

    // posix_spawn rather than Process, so the program starts with every signal at its
    // default: the TUI ignores SIGINT and friends, and an ignored signal is inherited.
    nonisolated private static func spawnAndWait(_ handoff: Handoff) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let directory = handoff.directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        let argv = handoff.arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawnp(&pid, handoff.arguments[0], &actions, &attributes, argv, environ) == 0 else {
            return -1
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return -1 }
        }
        // WIFEXITED / WEXITSTATUS, which Swift does not import as macros.
        return status & 0x7F == 0 ? (status >> 8) & 0xFF : -1
    }
}
