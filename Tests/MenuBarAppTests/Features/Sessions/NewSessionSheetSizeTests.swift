import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// Reports the height a view asks for when it is offered one, which is how a sheet that
// cannot be made shorter gives itself away.
private struct HeightProbe: Layout {
    let report: @Sendable (CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        report(size.height)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

@MainActor
private final class MeasuredHeight {
    var value: CGFloat = 0
}

// A sheet that asks for more height than the window it opens over is clipped rather than
// shrunk, and it is clipped from the middle out, so both of its ends go: the header at
// the top and the footer, with the Create button in it, at the bottom. The new session
// sheet grows once the branch check comes back, so it has to be able to give that height
// up again when the window is short.
struct NewSessionSheetSizeTests {
    private let testPreferences = TestPreferences()

    @MainActor
    @Test(arguments: [0, 200])
    func importKeepsItsActionsWithinAShortWindow(sessionCount: Int) throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store)
        let candidates = (0..<sessionCount).map { i in
            ExternalSessionCandidate(sessionID: "session-\(i)", agent: AgentKind.allCases[i % 3],
                file: scratch.path("history"), cwd: project.path, title: "Session \(i)",
                firstPrompt: "Hello", startedAt: nil, lastActivity: Date(), gitBranch: "main", bytes: 0)
        }
        let request = SessionImportRequest(folder: project.path, projectID: project.id,
                                           roots: [:], candidates: candidates)
        let measured = MeasuredHeight()
        let host = NSHostingView(rootView: HeightProbe(report: { height in
            MainActor.assumeIsolated { measured.value = height }
        }) {
            ImportSessionsView(request: request) { _ in }
                .environment(store)
                .environment(MenuPresenter())
                .environment(TooltipPresenter())
        })
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value > 200)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value <= 200)
    }

    @MainActor
    @Test func theSheetGivesUpHeightToAShortWindow() throws {
        let settings = AppSettings(
            agentAvatarURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("avatar.png"),
            preferences: UserDefaults(suiteName: "sheet-size-\(UUID().uuidString)") ?? .standard)
        let measured = MeasuredHeight()
        let host = NSHostingView(rootView: HeightProbe(report: { height in MainActor.assumeIsolated { measured.value = height } }) {
            NewSessionView(project: Project(name: "probe", path: NSTemporaryDirectory())) { _ in }
                .environment(SessionRunner(preferences: testPreferences.store, paths: [:]))
                .environment(DialogPresenter())
                .environment(MenuPresenter())
                .environment(TooltipPresenter())
                .environment(settings)
        })

        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        host.layoutSubtreeIfNeeded()
        let asked = measured.value
        #expect(asked > 200)

        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value <= 200)
    }

    @MainActor
    @Test(arguments: [CGFloat(560), CGFloat(760)])
    func troubleshootKeepsItsActionsWithinAShortWindow(width: CGFloat) throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store, named: "payments-api")
        let settings = AppSettings(
            agentAvatarURL: scratch.url.appendingPathComponent("avatar.png"),
            preferences: UserDefaults(suiteName: "troubleshoot-size-\(UUID().uuidString)")!)
        let measured = MeasuredHeight()
        let host = NSHostingView(rootView: HeightProbe(report: { height in MainActor.assumeIsolated { measured.value = height } }) {
            TroubleshootView(skills: SkillsManager(), initialProjectIDs: [project.id])
                .environment(store)
                .environment(SessionRunner(preferences: testPreferences.store, paths: [:]))
                .environment(ClaudeCodeManager())
                .environment(CodexCodeManager())
                .environment(CopilotCodeManager())
                .environment(ConfigStore(configURL: scratch.url.appendingPathComponent("config.json")))
                .environment(DialogPresenter())
                .environment(MenuPresenter())
                .environment(TooltipPresenter())
                .environment(settings)
        })

        host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value > 300)

        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value <= 300)
    }

}
