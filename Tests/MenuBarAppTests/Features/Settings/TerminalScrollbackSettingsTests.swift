import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct TerminalScrollbackSettingsTests {
    @Test(arguments: [false, true])
    func editingOnlyChangesHistoryWhenAValidLimitIsCommitted(reduceMotion: Bool) async throws {
        let (store, scratch) = TestStore.make()
        let preferences = scratch.preferences.store
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar"), preferences: preferences)
        settings.terminalScrollback = 5_000
        let shell = TerminalSession(directory: scratch.url.path, name: "Terminal",
                                    registry: ShellRegistry(directory: scratch.path("shells")),
                                    scrollback: settings.terminalScrollback)
        shell.surface.feed(text: (0..<2_000).map { "line-\($0)\r\n" }.joined())
        #expect(await waitUntil { shell.screenText().contains("line-1999") })
        #expect(shell.screenText().contains("line-0\n"))
        follow(settings, shell: shell)

        let view = SettingsView(skills: SkillsManager(preferences: preferences, siteSkills: { nil }))
            .environment(store)
            .environment(SessionRunner(store: store, preferences: preferences,
                                       persistentAgentSessions: false, paths: [:]))
            .environment(settings)
            .environment(StatsStore(fileURL: scratch.path("stats.json"),
                                    transcripts: scratch.path("transcripts")))
            .environment(LoginItem())
            .environment(AppUpdateChecker(preferences: preferences))
            .appOverlays()
            .environment(\._accessibilityReduceMotion, reduceMotion)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.appearance = NSAppearance(named: reduceMotion ? .darkAqua : .aqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        #expect(await waitUntil { field(in: hosting.view) != nil })
        let input = try #require(field(in: hosting.view))
        input.selectText(nil)
        let editor = try #require(input.currentEditor() as? NSTextView)
        try await type("10000", in: editor)
        #expect(settings.terminalScrollback == 5_000)
        #expect(Preferences.terminalScrollback.read(in: preferences) == 5_000)
        #expect(shell.screenText().contains("line-0\n"))
        try press("\r", keyCode: 36, in: window)
        #expect(await waitUntil { shell.surface.scrollbackLines == 10_000 })
        #expect(Preferences.terminalScrollback.read(in: preferences) == 10_000)
        #expect(shell.screenText().contains("line-0\n"))
        try snapshot(hosting.view, name: "saved", reduceMotion: reduceMotion)

        input.selectText(nil)
        try await type("1", in: editor)
        try press("\r", keyCode: 36, in: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string == "1")
        #expect(settings.terminalScrollback == 10_000)
        #expect(Preferences.terminalScrollback.read(in: preferences) == 10_000)
        #expect(shell.screenText().contains("line-0\n"))
        try snapshot(hosting.view, name: "invalid", reduceMotion: reduceMotion)
        try press("\u{1b}", keyCode: 53, in: window)
        #expect(await waitUntil { input.stringValue == "10000" })
        #expect(settings.terminalScrollback == 10_000)

        input.selectText(nil)
        let nextEditor = try #require(input.currentEditor() as? NSTextView)
        try await type("500", in: nextEditor)
        #expect(shell.screenText().contains("line-0\n"))
        window.makeFirstResponder(nil)
        #expect(await waitUntil { shell.surface.scrollbackLines == 500 })
        #expect(Preferences.terminalScrollback.read(in: preferences) == 500)
        #expect(!shell.screenText().contains("line-0\n"))
        #expect(shell.screenText().contains("line-1999"))
    }

    private func follow(_ settings: AppSettings, shell: TerminalSession) {
        withObservationTracking {
            shell.surface.setScrollback(settings.terminalScrollback)
        } onChange: { [weak settings, weak shell] in
            Task { @MainActor in
                guard let settings, let shell else { return }
                follow(settings, shell: shell)
            }
        }
    }

    private func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           field.placeholderString == "Lines" {
            return field
        }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    private func type(_ text: String, in editor: NSTextView) async throws {
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func press(_ text: String, keyCode: UInt16, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }

    private func snapshot(_ view: NSView, name: String, reduceMotion: Bool) throws {
        guard let directory = ProcessInfo.processInfo.environment["SCROLLBACK_REVIEW_DIRECTORY"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory)
            .appendingPathComponent("scrollback-\(name)-reduce-motion-\(reduceMotion).png"))
    }
}
