import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct MenuAnchorResizeTests {
    @Test(arguments: [false, true])
    func agentMenuFollowsItsButtonWhenTheDialogAndWindowResize(reduceMotion: Bool) async throws {
        let model = ResizingAgentDialog()
        let button = FrameAnchor()
        let host = NSHostingController(rootView: AgentDialogFixture(model: model, button: button)
            .appOverlays()
            .environment(\._accessibilityReduceMotion, reduceMotion))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(CGSize(width: 900, height: 760))
        host.view.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }

        await settle(host.view)
        let initialButton = try #require(button.frame())
        try click(initialButton, in: window)
        await settle(host.view)
        let menu = try #require(scrollView(in: host.view))
        let initialMenu = frame(of: menu, in: host.view)
        #expect(abs(initialMenu.maxY - initialButton.minY + 4) < 1)
        #expect(abs(initialMenu.minX - initialButton.minX) < 1)

        for (stage, warning, size) in [
            ("warning", true, CGSize(width: 900, height: 760)),
            ("resized", true, CGSize(width: 1100, height: 860)),
            ("collapsed", false, CGSize(width: 900, height: 760))
        ] {
            model.showsWarning = warning
            window.setContentSize(size)
            await settle(host.view)
            let control = try #require(button.frame())
            let menuFrame = frame(of: menu, in: host.view)
            #expect(abs(menuFrame.maxY - control.minY + 4) < 1)
            #expect(abs(menuFrame.minX - control.minX) < 1)
            #expect(menuFrame.size == initialMenu.size)
            if warning { #expect(control.minY > initialButton.minY + 40) }

            if let directory = ProcessInfo.processInfo.environment["MENU_ANCHOR_REVIEW_DIRECTORY"] {
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(stage)-reduce-\(reduceMotion).png"))
            }
        }

        let menuFrame = frame(of: menu, in: host.view)
        try click(CGRect(x: menuFrame.midX, y: menuFrame.midY, width: 0, height: 0), in: window)
        await settle(host.view)
        #expect(model.selected == "Codex")
        #expect(scrollView(in: host.view) == nil)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func frame(of view: NSView, in content: NSView) -> CGRect {
        FrameAnchor.fromTop(view.convert(view.bounds, to: content), in: content)
    }

    private func click(_ frame: CGRect, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let point = content.convert(CGPoint(x: frame.midX,
                                           y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY),
                                    to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

@MainActor
@Observable
private final class ResizingAgentDialog {
    var showsWarning = false
    var selected = "Claude Code"
}

private struct AgentDialogFixture: View {
    let model: ResizingAgentDialog
    let button: FrameAnchor

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New session").font(.serif(22, .semibold))
            Text("Project checkout").frame(height: 60)
            if model.showsWarning {
                Text("Origin did not answer. Showing the last fetched refs.")
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(Theme.attention.opacity(0.1))
            }
            CodingAgentPicker(title: model.selected, entries: [
                .item("Claude Code", checked: model.selected == "Claude Code",
                      subtitle: "Anthropic's coding agent.") { model.selected = "Claude Code" },
                .item("Codex", checked: model.selected == "Codex",
                      subtitle: "OpenAI's coding agent.") { model.selected = "Codex" },
                .item("Copilot", checked: model.selected == "Copilot",
                      subtitle: "GitHub's coding agent.") { model.selected = "Copilot" }
            ])
            .background(FrameAnchorView(anchor: button))
        }
        .padding(20)
        .frame(width: 680)
        .background(Theme.background)
        .smoothlyResizes(when: model.showsWarning)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
