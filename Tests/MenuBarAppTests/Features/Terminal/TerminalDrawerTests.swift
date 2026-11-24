import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct TerminalDrawerTests {
    @Test(arguments: [false, true])
    func maximizingFillsThePageAndRestoresItsHeight(reduceMotion: Bool) async throws {
        let pane = Pane(reduceMotion: reduceMotion)
        defer { pane.close() }
        let snapshots = ProcessInfo.processInfo.environment["TERMINAL_REVIEW_DIRECTORY"]
        if snapshots != nil { pane.window.orderFront(nil) }
        await pane.settle()
        let original = try #require(pane.state.drawer.frame())
        #expect(try #require(pane.state.page.frame()?.height) > 0)
        try pane.snapshot("normal", reduceMotion: reduceMotion, directory: snapshots)

        pane.terminals.setMaximized(true, for: pane.scope)
        try await Task.sleep(for: .milliseconds(60))
        try pane.snapshot("growing", reduceMotion: reduceMotion, directory: snapshots)
        await pane.settle()
        #expect(pane.state.page.frame()?.height == 0)
        #expect(pane.state.drawer.frame()?.height == pane.window.contentView?.bounds.height)
        try pane.snapshot("maximized", reduceMotion: reduceMotion, directory: snapshots)

        pane.terminals.setMaximized(false, for: pane.scope)
        await pane.settle()
        #expect(pane.state.drawer.frame() == original)
        try pane.snapshot("restored", reduceMotion: reduceMotion, directory: snapshots)
    }

    @Test func changingTheShortcutUpdatesBothTheWindowAndTheShell() async throws {
        let pane = Pane()
        defer { pane.close() }
        await pane.settle()
        let surface = try #require(pane.terminals.selection(for: pane.scope)?.surface)
        let original = try press("~", [.control, .shift], in: pane.window)
        let replacement = try press("m", [.command, .option], in: pane.window)
        #expect(pane.state.handler.take(original, from: pane.window, frontmost: pane.window))
        #expect(pane.terminals.isMaximized(pane.scope))

        pane.state.keys.set(KeyCombo("m", [.command, .option]), for: .maximizeTerminal)
        await pane.settle()
        pane.window.makeFirstResponder(nil)
        #expect(!pane.state.handler.take(original, from: pane.window, frontmost: pane.window))
        #expect(TerminalSurface.route(original, claimsKeys: true, drawerKeys: surface.drawerKeys,
                                     maximizeKeys: surface.maximizeKeys) == .shell)
        #expect(pane.state.handler.take(replacement, from: pane.window, frontmost: pane.window))
        #expect(!pane.terminals.isMaximized(pane.scope))
        #expect(TerminalSurface.route(replacement, claimsKeys: true, drawerKeys: surface.drawerKeys,
                                     maximizeKeys: surface.maximizeKeys) == .maximize)

        pane.state.keys.set(nil, for: .maximizeTerminal)
        await pane.settle()
        pane.window.makeFirstResponder(nil)
        #expect(!pane.state.handler.take(original, from: pane.window, frontmost: pane.window))
        #expect(!pane.state.handler.take(replacement, from: pane.window, frontmost: pane.window))
        #expect(TerminalSurface.route(original, claimsKeys: true, drawerKeys: surface.drawerKeys,
                                     maximizeKeys: surface.maximizeKeys) == .shell)

        pane.state.keys.reset(.maximizeTerminal)
        await pane.settle()
        pane.window.makeFirstResponder(nil)
        #expect(pane.state.handler.take(original, from: pane.window, frontmost: pane.window))
        #expect(pane.terminals.isMaximized(pane.scope))
    }

    @Test(arguments: ["dialog", "menu", "disabled"])
    func overlaysAndDisabledControlsBlockMaximizing(blocker: String) async throws {
        let pane = Pane()
        defer { pane.close() }
        await pane.settle()
        let dialogs = try #require(pane.state.dialogs)
        let menus = try #require(pane.state.menus)
        let surface = try #require(pane.terminals.selection(for: pane.scope)?.surface)
        let event = try press("~", [.control, .shift], in: pane.window)
        #expect(pane.state.handler.take(event, from: pane.window, frontmost: pane.window))
        pane.terminals.setMaximized(false, for: pane.scope)
        await pane.settle()

        switch blocker {
        case "dialog":
            var dialog = Dialog.notice("Confirm action")
            dialog.isModal = true
            dialogs.show(dialog)
        case "menu": menus.show([.item("Action") {}], at: .zero)
        default: pane.state.disabled = true
        }
        await pane.settle()
        pane.window.makeFirstResponder(nil)
        #expect(!pane.state.handler.take(event, from: pane.window, frontmost: pane.window))
        #expect(!pane.terminals.isMaximized(pane.scope))
        #expect(TerminalSurface.route(event, claimsKeys: surface.claimsKeys, drawerKeys: surface.drawerKeys,
                                     maximizeKeys: surface.maximizeKeys) == .app)

        dialogs.dismiss()
        menus.dismiss()
        pane.state.disabled = false
        await pane.settle()
        pane.window.makeFirstResponder(nil)
        #expect(pane.state.handler.take(event, from: pane.window, frontmost: pane.window))
        #expect(pane.terminals.isMaximized(pane.scope))
        #expect(TerminalSurface.route(event, claimsKeys: surface.claimsKeys, drawerKeys: surface.drawerKeys,
                                     maximizeKeys: surface.maximizeKeys) == .maximize)
    }

    private func press(_ key: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key,
                                     isARepeat: false, keyCode: 50))
    }

    @MainActor @Observable
    final class DrawerState {
        var keys = KeyBindings()
        var disabled = false
        let handler = WindowKeyHandler(handlesTyping: true)
        let page = FrameAnchor()
        let drawer = FrameAnchor()
        var dialogs: DialogPresenter?
        var menus: MenuPresenter?
    }

    private struct Fixture: View {
        @Environment(DialogPresenter.self) private var dialogs
        @Environment(MenuPresenter.self) private var menus
        @Environment(TerminalStore.self) private var terminals
        @State private var focused = false
        let scope: TerminalScope
        let state: DrawerState

        var body: some View {
            VStack(spacing: 0) {
                RetainedPane(hidden: terminals.isMaximized(scope)) {
                    VStack(spacing: Space.md) {
                        Text("Workspace").font(Typography.title)
                        Text("Review notes stay here while the terminal is maximized.").font(Typography.body)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                }
                .background(FrameAnchorView(anchor: state.page))
                TerminalDrawer(scope: scope, directory: "/private/tmp", focusTerminal: $focused,
                               maximizeHandler: state.handler)
                    .background(FrameAnchorView(anchor: state.drawer))
            }
            .environment(\.keyBindings, state.keys)
            .disabled(state.disabled)
            .onAppear { state.dialogs = dialogs; state.menus = menus }
        }
    }

    @MainActor
    private final class Pane {
        let terminals = TerminalStore(registry: ShellRegistry(directory: ShellNotes.scratch()))
        let scope = TerminalScope.project(UUID())
        let state = DrawerState()
        let window: NSWindow

        init(reduceMotion: Bool = false) {
            _ = NSApplication.shared
            terminals.reveal(scope, directory: "/private/tmp")
            let host = NSHostingController(rootView: Fixture(scope: scope, state: state)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .environment(terminals).appOverlays())
            host.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 800, height: 600))
            host.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.center()
        }

        func settle() async {
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(20))
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            window.close()
            window.contentViewController = nil
            terminals.stopEverything()
        }

        func snapshot(_ name: String, reduceMotion: Bool, directory: String?) throws {
            guard let directory, let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-reduce-\(reduceMotion).png"))
        }
    }
}
