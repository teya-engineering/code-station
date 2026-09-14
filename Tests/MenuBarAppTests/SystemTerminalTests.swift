import AppKit
import Foundation
import Testing
@testable import MenuBarApp

// Finding the terminals installed on a Mac comes down to one question: of all the apps
// that claim a shell script, which ones would run it rather than open it for editing.
@Suite(.serialized)
struct SystemTerminalTests {
    private let scratch = ScratchDirectory(prefix: "system-terminal-tests")

    // A stand-in app bundle, since the check reads the same Info.plist macOS reads.
    private func makeApp(named name: String, roles: [String]) throws -> URL {
        let app = scratch.path("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleDocumentTypes": roles.map { ["CFBundleTypeRole": $0] }
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func treatsAnAppThatRunsShellScriptsAsATerminal() throws {
        let app = try makeApp(named: "Pretendy", roles: ["Editor", "Editor", "Shell"])
        #expect(SystemTerminal.runsShellScripts(app))
    }

    // The reason the app list needs filtering at all: text editors, word processors and
    // browsers all claim a .command file, and macOS offers them alongside the terminals.
    @Test func leavesOutAnAppThatOnlyOpensShellScripts() throws {
        let editor = try makeApp(named: "Editorish", roles: ["Editor", "Viewer"])
        #expect(!SystemTerminal.runsShellScripts(editor))

        let viewer = try makeApp(named: "Viewerish", roles: ["Viewer", "None"])
        #expect(!SystemTerminal.runsShellScripts(viewer))
    }

    @Test func leavesOutAnAppThatClaimsNothing() throws {
        let app = try makeApp(named: "Blank", roles: [])
        #expect(!SystemTerminal.runsShellScripts(app))
    }

    @Test func readsTheNameWithoutTheExtension() {
        #expect(SystemTerminal.name(of: URL(fileURLWithPath: "/Applications/Ghostty.app")) == "Ghostty")
        #expect(SystemTerminal.name(of: SystemTerminal.fallback) == "Terminal")
    }

    // An app that is not installed leaves the choice unresolved, so the click falls back to
    // the system's terminal rather than doing nothing.
    @Test func fallsBackWhenTheChosenAppIsGone() {
        let saved = Preferences.terminalBundleID
        defer { Preferences.terminalBundleID = saved }

        Preferences.terminalBundleID = "com.example.terminal.that.is.not.installed"
        #expect(SystemTerminal.chosen == nil)
        #expect(SystemTerminal.appURL == SystemTerminal.systemDefault)
    }

    @Test func followsTheSystemWithoutAChoice() {
        let saved = Preferences.terminalBundleID
        defer { Preferences.terminalBundleID = saved }

        Preferences.terminalBundleID = nil
        #expect(SystemTerminal.appURL == SystemTerminal.systemDefault)
    }

    // Terminal is always there, and it is what the app has to fall back to, so it has to
    // survive the filter on any Mac the tests run on.
    @Test func listsTheSystemTerminal() {
        let installed = SystemTerminal.installed
        #expect(installed.contains(SystemTerminal.systemDefault))
        #expect(installed.contains { SystemTerminal.name(of: $0) == "Terminal" })
    }

    // The same terminal is often registered from more than one copy on disk, and the list
    // is a menu of apps rather than of the places they are installed.
    @Test func listsEachAppOnce() {
        let ids = SystemTerminal.installed.compactMap(SystemTerminal.bundleID(of:))
        #expect(ids.count == Set(ids).count)
    }
}

// The terminal setting answers one question - where a shell opens - so the header button
// acts on the answer rather than putting it to the user a second time.
@Suite(.serialized)
@MainActor
struct TerminalDestinationTests {
    private func labels(_ entries: [MenuEntry]) -> [String] {
        entries.compactMap { entry in
            guard case let .item(item) = entry else { return nil }
            return item.label
        }
    }

    @Test func opensInTheDrawerUntilATerminalAppIsPicked() {
        let defaults = UserDefaults(suiteName: "terminal-destination-\(UUID().uuidString)")!
        let settings = AppSettings(agentAvatarURL: URL(fileURLWithPath: "/tmp/avatar"),
                                   preferences: defaults)

        #expect(settings.opensTerminalInDrawer)

        settings.terminalBundleID = "com.example.terminal"
        #expect(!settings.opensTerminalInDrawer)

        settings.terminalBundleID = nil
        #expect(settings.opensTerminalInDrawer)
    }

    // The menu leads with what pressing the button already does, so the row that repeats
    // the press comes first and the other way out sits under it.
    @Test func leadsTheMenuWithWhatThePressDoes() {
        let saved = Preferences.terminalBundleID
        defer { Preferences.terminalBundleID = saved }

        Preferences.terminalBundleID = nil
        let drawerFirst = labels(terminalEntries(isOpen: false, toggle: {}, directory: "/tmp"))
        #expect(drawerFirst.first == "Open terminal here")
        #expect(drawerFirst.count == 2)

        Preferences.terminalBundleID = "com.apple.Terminal"
        let appFirst = labels(terminalEntries(isOpen: false, toggle: {}, directory: "/tmp"))
        #expect(appFirst.first == "Open in \(SystemTerminal.appName)")
        #expect(appFirst.last == "Open terminal here")
    }

    // The drawer row says whether the press will put it away, so the words match the state
    // rather than always offering to open one.
    @Test func namesTheDrawerRowForWhatItWillDo() {
        let saved = Preferences.terminalBundleID
        defer { Preferences.terminalBundleID = saved }

        Preferences.terminalBundleID = nil
        #expect(labels(terminalEntries(isOpen: true, toggle: {}, directory: "/tmp")).first
                == "Hide terminal here")
    }
}
