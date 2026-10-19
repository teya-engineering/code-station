import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// The ask dialog sits centred over a tall window, so it is offered far more height than
// it needs. It must keep to its content rather than stretch to fill it.
@MainActor
struct SecondOpinionAskLayoutTests {
    private let testPreferences = TestPreferences()

    @Test func theAskDialogKeepsToItsContentInATallWindow() {
        var height: CGFloat = 0
        let ask = ChangesOpinionAsk(
            author: SecondOpinion.Reviewer(agent: .claudeCode), installed: [.codex, .copilot, .claudeCode],
            running: [], lineup: [SecondOpinion.Reviewer(agent: .codex)], focus: [], scope: .all,
            fileCount: 19, fileName: "App.swift", canReadSince: false, ask: { _, _, _ in })
        let root = ZStack {
            ask.frame(width: 620)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(width: 1400, height: 1200)
        .environment(DialogPresenter())
        .environment(SessionRunner(preferences: testPreferences.store, paths: [:]))
        .environment(TooltipPresenter())
        .environment(MenuPresenter())

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 1200)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        #expect(height > 200)
        #expect(height < 600)
    }
}
