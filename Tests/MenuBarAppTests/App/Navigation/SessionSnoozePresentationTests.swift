import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SessionSnoozePresentationTests {
    private let preferences = TestPreferences()

    @Test(arguments: [CGFloat(220), 270, 318], [false, true])
    func snoozedCardFitsWithoutHidingItsReturnCondition(width: CGFloat, selected: Bool) {
        let content = SnoozeCardPreview(selected: selected)
            .environment(AppSettings(preferences: preferences.store))
            .environment(PullRequestReviewStore())
            .appOverlays()
        let host = NSHostingController(rootView: content)
        let size = host.sizeThatFits(in: CGSize(width: width, height: .infinity))
        #expect(size.width <= width)
        #expect(size.height >= 120)
        #expect(size.height < 210)
    }

    @Test func tagOnlyMovesForAVisibleStateChange() throws {
        let tag = SessionSnoozeTagView(frame: CGRect(x: 0, y: 0, width: 39, height: 66))
        let window = SnoozeVisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(tag)
        defer { window.close() }
        let drawing = try #require(tag.layer?.sublayers?.first)
        func update(_ snoozed: Bool, reduced: Bool = false) {
            tag.update(snoozed: snoozed, reduceMotion: reduced, paper: NSColor.gray.cgColor,
                       ink: NSColor.black.cgColor, edge: NSColor.gray.cgColor, hole: NSColor.white.cgColor)
        }
        update(true)
        #expect((drawing.animationKeys() ?? []).isEmpty)
        #expect(drawing.opacity == 1)
        update(false)
        #expect(drawing.animation(forKey: "lift") != nil)
        #expect(drawing.opacity == 0)
        update(true)
        let swing = try #require(drawing.animation(forKey: "swing"))
        #expect(swing.repeatCount == 0)
        #expect(swing.duration == Motion.popDuration + Motion.controlDuration)
        drawing.removeAllAnimations()
        update(true)
        #expect((drawing.animationKeys() ?? []).isEmpty)
        update(false, reduced: true)
        #expect(drawing.animation(forKey: "lift") == nil)
        #expect(drawing.animation(forKey: "swing") == nil)
        #expect(drawing.animation(forKey: "fade") != nil)
        drawing.removeAllAnimations()
        window.shown = false
        update(true)
        #expect((drawing.animationKeys() ?? []).isEmpty)
        #expect(tag.hitTest(.zero) == nil)
        #expect(!tag.isAccessibilityElement())
    }

    @Test func changeSnoozeStartsWithTheCurrentChoiceAndCancelPreservesIt() throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        let now = Date()
        for choice in SessionSnooze.Choice.allCases {
            let snooze = choice.snooze(now: now)
            store.snooze(session.id, snooze)
            let picked = SnoozeChoice(snooze: snooze, now: now)
            #expect(picked.choice.snooze(now: picked.now) == snooze)
            let dialogs = DialogPresenter()
            dialogs.show(SessionSnoozeDialog.make(for: session, store: store))
            dialogs.dismiss()
            #expect(store.snooze(of: session.id) == snooze)
        }
        withExtendedLifetime(scratch) {}
    }

    @Test func confirmingAnExistingSnoozeKeepsItsDeadlineAndLocation() throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        let snooze = SessionSnooze.Choice.morning.snooze()
        store.snooze(session.id, snooze)
        let dialog = SessionSnoozeDialog.make(for: session, store: store)
        try #require(dialog.actions.first).handler()
        #expect(store.snooze(of: session.id) == snooze)
        #expect(store.session(session.id)?.projectID == project.id)
        SessionSnoozeMenu.wake(session.id, store: store)
        #expect(!store.isSnoozed(session.id))
        #expect(store.session(session.id)?.projectID == project.id)
        withExtendedLifetime(scratch) {}
    }

    @Test func rendersSnoozeStatesForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["SNOOZE_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for dark in [false, true] {
            for reduced in [false, true] {
                let (store, scratch) = TestStore.make()
                let project = try TestStore.project(in: store)
                let session = store.newSession(in: project.id)
                store.snooze(session.id, .untilWoken)
                let content = SnoozeReviewPreview(store: store, session: session)
                    .environment(AppSettings(preferences: preferences.store))
                    .environment(PullRequestReviewStore())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    // Override only the test window, leaving the macOS preference alone.
                    .environment(\._accessibilityReduceMotion, reduced)
                    .appOverlays()
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 620),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Snooze review - \(dark ? "dark" : "light") - motion \(reduced ? "off" : "on")"
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(350))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("\(dark ? "dark" : "light")-\(reduced).png"))
                if ProcessInfo.processInfo.environment["SNOOZE_INTERACTIVE"] != nil {
                    try await Task.sleep(for: .seconds(45))
                }
                withExtendedLifetime(scratch) {}
            }
        }
    }
}

private final class SnoozeVisibilityWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}

private struct SnoozeCardPreview: View {
    var selected = true
    var snooze: SessionSnooze? = .untilWoken
    var wake: () -> Void = {}

    var body: some View {
        let session = ChatSession(projectID: UUID())
        SessionCard(session: withTitle(session), worktrees: .init(isolated: ["code-station"]),
                    selected: selected, busy: true, failed: false, waiting: false,
                    waitIsStale: false, waitingSince: nil, needsInput: false, finished: false,
                    snoozed: snooze, activity: { "Refining the session cards" }, branch: "main",
                    uncommitted: false, connected: false, isRenaming: false, checked: nil,
                    onOpen: {}, onWake: wake, onDelete: {}, onRename: { _ in }, onCancelRename: {})
    }

    private func withTitle(_ session: ChatSession) -> ChatSession {
        var session = session
        session.title = "Refine the session sidebar with a deliberately long title"
        return session
    }
}

private struct SnoozeReviewPreview: View {
    let store: ProjectStore
    let session: ChatSession
    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        let snooze = store.snooze(of: session.id)
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                ForEach([CGFloat(220), 250, 270], id: \.self) { width in
                    SnoozeCardPreview(selected: width == 270, snooze: snooze) {
                        SessionSnoozeMenu.wake(session.id, store: store)
                    }
                    .frame(width: width)
                }
            }
            if let snooze {
                SessionSnoozeStrip(snooze: snooze) { SessionSnoozeMenu.wake(session.id, store: store) }
            }
            HStack {
                ActionButton(title: "Snooze") { store.snooze(session.id, .untilWoken) }
                ActionButton(title: "Change snooze") {
                    dialogs.show(SessionSnoozeDialog.make(for: session, store: store))
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}
