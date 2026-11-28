import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct AttachProjectSheetTests {
    init() {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
    }

    // Open, type, Return: the search field takes the keyboard as the sheet opens, and
    // Return picks the row under the cursor, which puts the list away.
    @Test(arguments: [false, true])
    func aProjectIsPickedWithTheKeyboardAlone(reduceMotion: Bool) async throws {
        let (store, scratch) = TestStore.make()
        let projects = try ["code-station", "engineering", "Branch whitelist",
                            "payments-gateway-acceptance-tests-and-contract-fixtures", "design-notes"]
            .map { name -> Project in
                let folder = scratch.path("folders/\(name)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try #require(store.addProject(at: folder))
            }
        let session = store.newSession(in: projects[0].id, worktreeBranch: "code-station/8bc627ed")
        var attached: [String] = []
        let host = NSHostingController(rootView:
            AttachProjectSheet(sessionID: session.id) { project, _ in attached.append(project.name) }
                .environment(store)
                .environment(SessionRunner(store: store, preferences: scratch.preferences.store, paths: [:]))
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .appOverlays())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = host
        defer { window.contentViewController = nil }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        #expect(await waitUntil { window.firstResponder is NSTextView })
        await settle(host.view, rounds: 40)
        try snapshot(host.view, named: "attach-choose-\(reduceMotion)")
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("engin", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host.view)
        try snapshot(host.view, named: "attach-search-\(reduceMotion)")

        editor.insertNewline(nil)
        #expect(await waitUntil { !(window.firstResponder is NSTextView) })
        await settle(host.view, rounds: 40)
        try snapshot(host.view, named: "attach-setup-\(reduceMotion)")
        // Nothing is attached until Attach is pressed.
        #expect(attached.isEmpty)
        #expect(store.checkoutProjects(for: try #require(store.session(session.id))).count == 1)
    }

    @Test func aSearchWithNoMatchSaysSo() async throws {
        let (store, scratch) = TestStore.make()
        let lead = try TestStore.project(in: store, named: "lead")
        _ = try TestStore.project(in: store, named: "other")
        let session = store.newSession(in: lead.id)
        let host = NSHostingController(rootView:
            AttachProjectSheet(sessionID: session.id) { _, _ in }
                .environment(store)
                .environment(SessionRunner(store: store, preferences: scratch.preferences.store, paths: [:]))
                .appOverlays())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = host
        defer { window.contentViewController = nil }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        #expect(await waitUntil { window.firstResponder is NSTextView })
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("payments", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host.view)
        try snapshot(host.view, named: "attach-no-match")
        // Return has nothing to pick, so the search stays where it is.
        editor.insertNewline(nil)
        await settle(host.view)
        #expect(window.firstResponder is NSTextView)
    }

    private func snapshot(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GLANCE_REVIEW_DIRECTORY"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func settle(_ view: NSView, rounds: Int = 15) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }
}
