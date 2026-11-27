import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The switch dialog is one screen: whichever handoff is picked, and with the Full access
// warning folded in, the review stands at the same width and under the dialog's height
// limit, so nothing has to scroll.
@MainActor
@Suite(.serialized)
struct AgentSwitchDialogLayoutTests {
    private let testPreferences = TestPreferences()

    @Test(arguments: AgentHandoff.allCases, [false, true])
    func theReviewFitsOnOneScreen(handoff: AgentHandoff, fullAccess: Bool) async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "hello\nand more\n")
        try repo.write("Sources/App/AgentSwitchDialog.swift", String(repeating: "line\n", count: 40))
        let (store, scratch) = TestStore.make()
        _ = scratch
        let project = try #require(store.addProject(at: repo.url))
        let runner = SessionRunner(store: store, preferences: testPreferences.store, paths: [:])
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Cut the switch dialog down to one screen."), to: session.id)
        store.append(ChatMessage(role: .assistant, text: "Done. The dialog now hugs its content."), to: session.id)
        store.recordContext(48_200, contextWindow: 200_000, model: "opus", from: .claudeCode, for: session.id)
        let draft = try #require(AgentSwitchDraft(sessionID: session.id, to: .codex, store: store,
                                                  runner: runner))
        draft.draftNote(by: .app)
        draft.handoff = handoff
        if fullAccess { draft.access = .codex(.fullAccess) }
        await draft.readWorktree()

        try await expectFits(draft, name: "\(handoff.rawValue)\(fullAccess ? "-full" : "")")
    }

    @Test func aNoteThatFellBackAndAStoppedHandoverStillFit() async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        // Codex is found, so it can be asked for the note, but it prints no version an
        // app could accept. Claude Code is not installed, so it never answers.
        let codex = scratch.path("codex")
        try "#!/bin/sh\necho 'codex-cli 0.1.0'\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let runner = SessionRunner(store: store, preferences: testPreferences.store, paths: [.codex: codex.path])
        let session = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Cut the switch dialog down to one screen."), to: session.id)
        let draft = try #require(AgentSwitchDraft(sessionID: session.id, to: .codex, store: store,
                                                  runner: runner))

        draft.draftNote()
        #expect(await waitUntil { !draft.isDrafting })
        #expect(draft.silentWriter == .outgoing)
        await draft.readWorktree()
        try await expectFits(draft, name: "fell-back")

        draft.showsWhy = true
        try await expectFits(draft, name: "why")
        draft.showsWhy = false

        draft.start {}
        #expect(await waitUntil { draft.isFailed })
        try await expectFits(draft, name: "stopped")
    }

    private func expectFits(_ draft: AgentSwitchDraft, name: String) async throws {
        for dark in [false, true] {
            let view = HuggingHeight { AgentSwitchDialog(draft: draft) }
                .frame(width: FormMetrics.sheetWidth)
                .environment(DialogPresenter()).environment(MenuPresenter()).environment(TooltipPresenter())
                .environment(\.colorScheme, dark ? .dark : .light)
                // One appearance plays the entrance and the other stands still, so both
                // ways of arriving are laid out.
                .environment(\._accessibilityReduceMotion, !dark)
            let host = NSHostingView(rootView: view)
            let size = CGSize(width: FormMetrics.sheetWidth, height: 900)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))

            let fitting = host.fittingSize
            #expect(fitting.width == FormMetrics.sheetWidth)
            // The dialog host never gives a dialog more than this, in a window of any height.
            #expect(fitting.height <= Dialog(title: "", actions: []).maximumHeight)

            if let folder = ProcessInfo.processInfo.environment["AGENT_SWITCH_PREVIEWS"] {
                window.setContentSize(fitting)
                host.frame = NSRect(origin: .zero, size: fitting)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(800))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(
                        "\(name)-\(dark ? "dark" : "light")-\(Int(fitting.height)).png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}
