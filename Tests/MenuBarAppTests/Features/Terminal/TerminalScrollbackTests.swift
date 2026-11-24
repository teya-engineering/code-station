import Foundation
import Testing
@testable import MenuBarApp

// How far back a drawer shell can be scrolled, picked in Settings.
@MainActor
struct TerminalScrollbackTests {
    @Test func tenThousandIsTheDefaultAndThePickIsKeptInRange() {
        let defaults = scratchDefaults()

        #expect(Preferences.terminalScrollback.read(in: defaults) == 10_000)
        Preferences.terminalScrollback.write(500, in: defaults)
        #expect(Preferences.terminalScrollback.read(in: defaults) == 500)
        Preferences.terminalScrollback.write(25_500, in: defaults)
        #expect(Preferences.terminalScrollback.read(in: defaults) == 25_500)
        defaults.set(123, forKey: "terminalScrollback")
        #expect(Preferences.terminalScrollback.read(in: defaults) == 500)
        defaults.set(5_000_000, forKey: "terminalScrollback")
        #expect(Preferences.terminalScrollback.read(in: defaults) == 100_000)
    }

    @Test func aShellStartsWithTheDepthItIsGiven() {
        let shell = TerminalSession(directory: FileManager.default.temporaryDirectory.path,
                                    name: "Terminal",
                                    registry: ShellRegistry(directory: ShellNotes.scratch()),
                                    scrollback: 1_000)
        #expect(shell.surface.scrollbackLines == 1_000)
    }

    @Test func openTabsTakeANewDepthAtOnce() {
        let terminals = TerminalStore(registry: ShellRegistry(directory: ShellNotes.scratch()))
        terminals.scrollback = 5_000
        let scope = TerminalScope.session(UUID())
        let shell = terminals.add(to: scope, directory: FileManager.default.temporaryDirectory.path)
        defer { terminals.discard(scope) }

        #expect(shell.surface.scrollbackLines == 5_000)
        terminals.scrollback = 100_000
        #expect(shell.surface.scrollbackLines == 100_000)
    }

    @Test func anAssignedSizeIsHeldToTheRange() {
        let defaults = scratchDefaults()
        let settings = AppSettings(agentAvatarURL: FileManager.default.temporaryDirectory
                                       .appendingPathComponent(UUID().uuidString),
                                   preferences: defaults)

        settings.terminalScrollback = 12_345
        #expect(settings.terminalScrollback == 12_345)
        settings.terminalScrollback = 10
        #expect(settings.terminalScrollback == 500)
        settings.terminalScrollback = 1_000_000
        #expect(settings.terminalScrollback == 100_000)
        #expect(Preferences.terminalScrollback.read(in: defaults) == 100_000)
    }
}
