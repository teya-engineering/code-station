import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct RetainedPaneTests {
    @Test(arguments: [false, true])
    func hidingAPageKeepsItsDraftsAndViewportButDisablesItsKeys(reduceMotion: Bool) async throws {
        let state = PaneState()
        let content = FrameAnchor()
        let allocation = FrameAnchor()
        let host = NSHostingController(rootView: Fixture(state: state, content: content, allocation: allocation)
            .environment(\._accessibilityReduceMotion, reduceMotion))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 800, height: 600))
        host.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.center()
        defer { window.close(); window.contentViewController = nil; state.handler.stop(); state.monitor.stop() }
        await settle(host.view)
        let draft = try #require(state.draft)
        draft.message = "Keep the current work"
        draft.excluded = ["other.swift"]
        let comment = CommentDraft(anchor: .init(side: .new, line: 1), path: "file.swift", text: "Keep this note")
        state.comment?.wrappedValue = comment
        await settle(host.view)
        let size = try #require(content.frame()?.size)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                modifierFlags: .command, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: "b", charactersIgnoringModifiers: "b",
                                                isARepeat: false, keyCode: 11))
        #expect(state.handler.take(event, from: window, frontmost: window))

        state.hidden = true
        await settle(host.view)
        #expect(content.frame()?.size == size)
        #expect(allocation.frame()?.height == 0)
        #expect(!state.handler.take(event, from: window, frontmost: window))
        #expect(!state.monitor.isEnabled)
        #expect(state.appearances == 1)
        #expect(state.disappearances == 0)

        state.hidden = false
        await settle(host.view)
        #expect(content.frame()?.size == size)
        #expect(state.draft === draft)
        #expect(state.draft?.message == "Keep the current work")
        #expect(state.draft?.excluded == ["other.swift"])
        #expect(state.comment?.wrappedValue == comment)
        #expect(state.appearances == 1)
        #expect(state.handler.take(event, from: window, frontmost: window))
        #expect(state.monitor.isEnabled)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor @Observable
    final class PaneState {
        var hidden = false
        var appearances = 0
        var disappearances = 0
        var draft: ChangesCommitDraft?
        var comment: Binding<CommentDraft?>?
        let handler = WindowKeyHandler()
        let monitor = WindowKeyMonitor(KeyCombo("b"))
    }

    private struct Fixture: View {
        let state: PaneState
        let content: FrameAnchor
        let allocation: FrameAnchor

        var body: some View {
            VStack(spacing: 0) {
                RetainedPane(hidden: state.hidden) {
                    DraftPage(state: state).background(FrameAnchorView(anchor: content))
                }
                .background(FrameAnchorView(anchor: allocation))
                Color.clear.frame(maxHeight: state.hidden ? .infinity : 0)
            }
        }
    }

    private struct DraftPage: View {
        let state: PaneState
        @State private var draft = ChangesCommitDraft()
        @State private var comment: CommentDraft?

        var body: some View {
            Text(draft.message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowKeyAnchor(handler: state.handler))
                .background(WindowAnchor(monitor: state.monitor))
                .onAppear {
                    state.draft = draft
                    state.comment = $comment
                    state.appearances += 1
                    state.handler.start { _ in true }
                    state.monitor.start { true }
                }
                .onDisappear { state.disappearances += 1 }
        }
    }
}
