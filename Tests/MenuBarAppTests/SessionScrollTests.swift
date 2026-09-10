import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SessionScrollTests {
    @Test(arguments: [false, true])
    func submittingAndQueuingPromptsResumeFollowingALongTranscript(multiline: Bool) async throws {
        let pane = try Pane()
        defer { pane.harness.tearDown() }
        let scroll = try await pane.transcript()
        let editor = try #require(pane.views.compactMap { $0 as? NSTextView }
            .first { $0.isEditable })

        let firstPrompt = multiline
            ? "Start the next turn\nKeep the changes focused.\nRun the tests before finishing."
            : "Start the next turn"
        for prompt in [firstPrompt, "Queue another prompt"] {
            pane.scroll(scroll, awayFromBottom: 300)
            await pane.settle()
            #expect(pane.distanceFromBottom(scroll) > 100)

            pane.harness.runner.editDraft(pane.harness.session.id) { $0.text = prompt }
            await pane.settle()
            #expect(editor.delegate?.textView?(
                editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
            await pane.settle()

            #expect(pane.harness.runner.draft(pane.harness.session.id).isEmpty)
            #expect(abs(pane.distanceFromBottom(scroll)) < 2)
        }

        #expect(pane.harness.store.transcript(of: pane.harness.session.id)
            .contains { $0.role == .user && $0.text == firstPrompt })
        #expect(pane.harness.runner.queued(pane.harness.session.id).map(\.text)
            == ["Queue another prompt"])
    }

    @Test func incomingTextRespectsReadingEarlierMessagesAndFollowsNearTheBottom() async throws {
        let pane = try Pane()
        defer { pane.harness.tearDown() }
        let scroll = try await pane.transcript()
        let message = try #require(pane.harness.store.transcript(of: pane.harness.session.id).last)

        pane.scroll(scroll, awayFromBottom: 300)
        await pane.settle()
        pane.harness.store.updateMessage(message.id, in: pane.harness.session.id) {
            $0.text += "\n\nMore text while reading an earlier message."
        }
        await pane.settle()
        #expect(pane.distanceFromBottom(scroll) > 100)

        pane.scroll(scroll, awayFromBottom: 12)
        await pane.settle()
        pane.harness.store.updateMessage(message.id, in: pane.harness.session.id) {
            $0.text += "\n\nMore text while following the conversation."
        }
        await pane.settle()
        #expect(abs(pane.distanceFromBottom(scroll)) < 2)
    }

    @MainActor
    private final class Pane {
        let harness: RunnerHarness
        let window: NSWindow
        let view: NSView

        init() throws {
            harness = try RunnerHarness(agent: .claudeCode, script: """
            IFS= read -r input
            printf '%s\n' '{"type":"system","subtype":"init","session_id":"scroll-fixture"}'
            wait_for "$folder/finish"
            """)
            harness.store.selection = .session(harness.session.id)
            for index in 0..<40 {
                harness.store.append(ChatMessage(role: .assistant, text:
                    "Message \(index)\n\n" + String(repeating:
                        "A long conversation needs room to read earlier messages. ", count: 8)),
                    to: harness.session.id)
            }
            let preferences = try #require(UserDefaults(suiteName: "scroll-\(UUID().uuidString)"))
            let settings = AppSettings(agentAvatarURL: harness.scratch.path("avatar.png"),
                                       preferences: preferences)
            let hosting = NSHostingController(rootView:
                SessionView(sessionID: harness.session.id)
                    .environment(harness.store)
                    .environment(harness.runner)
                    .environment(TerminalStore())
                    .environment(settings)
                    .environment(GitStatsCache())
                    .environment(ShortcutStore(storageURL: harness.scratch.path("shortcuts.json"),
                                               siteDefaults: SiteDefaults()))
                    .environment(GlobalCommandPaletteController())
                    .appOverlays())
            hosting.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = hosting
            view = hosting.view
        }

        var views: [NSView] {
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews + view.subviews.flatMap(descendants)
            }
            return descendants(view)
        }

        func transcript() async throws -> NSScrollView {
            await settle()
            let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first {
                !($0.documentView is NSTextView)
                    && $0.contentView.documentRect.height > $0.documentVisibleRect.height + 1000
            })
            #expect(abs(distanceFromBottom(scroll)) < 2)
            return scroll
        }

        func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
            let document = scroll.contentView.documentRect
            let visible = scroll.documentVisibleRect
            return scroll.documentView?.isFlipped == true
                ? document.maxY - visible.maxY
                : visible.minY - document.minY
        }

        func scroll(_ scroll: NSScrollView, awayFromBottom distance: CGFloat) {
            let document = scroll.contentView.documentRect
            let visible = scroll.documentVisibleRect
            let y = scroll.documentView?.isFlipped == true
                ? document.maxY - visible.height - distance
                : document.minY + distance
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification,
                                            object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                            object: scroll)
        }

        func settle() async {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(20))
                view.layoutSubtreeIfNeeded()
            }
        }
    }
}
