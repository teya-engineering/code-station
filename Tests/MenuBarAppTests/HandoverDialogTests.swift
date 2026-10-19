import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The Dialog a handover shows when turns are still running after a short wait (ADR-0003):
// the turns by name, and the choice to wait for them or stop them.
@MainActor
struct HandoverDialogTests {
    private let turns = [
        RemoteRunningTurn(sessionID: UUID().uuidString, title: "Fix login", project: "acorn-api"),
        RemoteRunningTurn(sessionID: UUID().uuidString, title: "Tidy styles (Design)", project: "acorn-web")
    ]

    @Test func asksToWaitForTheTurnsOrStopThem() {
        var waited = 0, stopped = 0
        let dialog = Dialog.runningTurns(turns, message: "Code Station takes over once they end.",
                                         waiting: false, wait: { waited += 1 }, stop: { stopped += 1 })

        #expect(dialog.title == "2 turns are still running")
        #expect(dialog.message == "Code Station takes over once they end.")
        #expect(dialog.content != nil)
        #expect(dialog.actions.map(\.label) == ["Wait for them", "Stop them"])
        #expect(dialog.actions.map(\.kind) == [.primary, .destructive])

        let presenter = DialogPresenter()
        presenter.show(dialog)
        presenter.dismiss()
        #expect(waited == 1 && stopped == 0)
        presenter.show(dialog)
        presenter.run(dialog.actions[1])
        #expect(presenter.current == nil)
        #expect(waited == 1 && stopped == 1)
        presenter.show(dialog)
        presenter.run(dialog.actions[0])
        #expect(waited == 2 && stopped == 1)
    }

    // Once the person chose to wait, the Dialog says so and keeps only the way to stop.
    @Test func whileWaitingOnlyOffersToStop() {
        var stopped = 0
        let dialog = Dialog.runningTurns(Array(turns.prefix(1)), message: "", waiting: true,
                                         wait: {}, stop: { stopped += 1 })

        #expect(dialog.title == "Waiting for a turn to end")
        #expect(dialog.actions.map(\.label) == ["Stop it"])
        dialog.actions[0].handler()
        #expect(stopped == 1)
    }

    @Test func drawsInsideTheWindow() async throws {
        let presenter = DialogPresenter()
        presenter.show(.runningTurns(turns, message: "Code Station takes over from the background service "
                                         + "once they end. Wait for them, or stop them and keep what they have done.",
                                     waiting: false, wait: {}, stop: {}))
        let host = NSHostingView(rootView: Theme.background.overlay { DialogHost() }.environment(presenter))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        // The card's parts arrive one after another, so it is drawn once they have.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.center()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["HANDOVER_DIALOG_PREVIEWS"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("handover-dialog.png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }
}
