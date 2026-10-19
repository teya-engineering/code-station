import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct FirstRunLayoutTests {
    @Test(arguments: FirstRunSetup.Step.allCases, [CGFloat(1), 1.3])
    func keepsTheFooterInsideAShortWindow(step: FirstRunSetup.Step, scale: CGFloat) {
        let setup = FirstRunSetup(initialAgent: .codex)
        setup.step = step
        setup.usesTeamSettings = true
        setup.loader.failure = String(repeating: "The team configuration could not be saved. ", count: 8)
        let measurement = FirstRunMeasurement()
        let host = NSHostingView(rootView: FirstRunSizeProbe(report: { measurement.size = $0 }) {
            content(setup, state: .notInstalled)
                .environment(\.textScale, scale)
                .environment(DialogPresenter())
        })
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
        host.layoutSubtreeIfNeeded()
        #expect(measurement.size.height <= 620)
        #expect(measurement.size.height > 200)
        host.frame.size.height = 300
        host.layoutSubtreeIfNeeded()
        #expect(measurement.size.height <= 300)
    }

    @Test func rendersOnboardingStatesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["FIRST_RUN_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for dark in [false, true] {
            for state in [AgentReadiness.connected, .notInstalled, .signInNeeded, .checking, .failed] {
                let setup = FirstRunSetup(initialAgent: .codex)
                try capture(content(setup, state: state), dark: dark,
                            to: destination.appendingPathComponent("agent-\(state)-\(dark).png"))
            }
            for team in [false, true] {
                let setup = FirstRunSetup(initialAgent: .codex)
                setup.step = .configuration
                setup.usesTeamSettings = team
                if team { setup.loader.failure = "The configuration could not be saved. Choose another file or try again." }
                try capture(content(setup, state: .connected), dark: dark,
                            to: destination.appendingPathComponent("team-\(team)-\(dark).png"))
            }
            for selected in [false, true] {
                let setup = FirstRunSetup(initialAgent: .codex)
                setup.step = .project
                if selected { setup.projectURL = URL(fileURLWithPath: "/private/tmp/acorn-api") }
                try capture(content(setup, state: .connected), dark: dark,
                            to: destination.appendingPathComponent("project-\(selected)-\(dark).png"))
            }
            let dialogs = DialogPresenter()
            dialogs.show(FirstRunTour.dialog(closeTitle: "Back to setup"))
            try capture(Theme.background.overlay { DialogHost() }, dark: dark,
                        to: destination.appendingPathComponent("tour-\(dark).png"), dialogs: dialogs)
        }
        let setup = FirstRunSetup(initialAgent: .claudeCode)
        try capture(content(setup, state: .failed).environment(\.textScale, 1.3), dark: false,
                    to: destination.appendingPathComponent("large-text.png"))
    }

    private func content(_ setup: FirstRunSetup, state: AgentReadiness) -> some View {
        FirstRunWizardContent(setup: setup,
                              readiness: [.claudeCode: .notInstalled, .codex: state, .copilot: .signInNeeded],
                              refresh: { _ in }, openTerminal: { _ in },
                              applyConfiguration: {}, finish: { _ in })
    }

    private func capture(_ view: some View, dark: Bool, to url: URL,
                         dialogs: DialogPresenter = DialogPresenter()) throws {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(dialogs))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private final class FirstRunMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var measured = CGSize.zero

    var size: CGSize {
        get { lock.withLock { measured } }
        set { lock.withLock { measured = newValue } }
    }
}

private struct FirstRunSizeProbe: Layout {
    let report: @Sendable (CGSize) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        report(size)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}
