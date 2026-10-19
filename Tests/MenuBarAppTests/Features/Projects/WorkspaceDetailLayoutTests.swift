import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The workspace page sits next to the sidebar in a window the user can make narrow. If
// any part of it refuses to shrink, SwiftUI widens the whole window content past the
// window, and both the sidebar and the page get cut off at the edges.
@MainActor
struct WorkspaceDetailLayoutTests {
    private let testPreferences = TestPreferences()

    @Test func aBusyWorkspaceStillFitsTheNarrowestWindow() async throws {
        let (store, scratch) = TestStore.make()
        let settings = AppSettings(
            agentAvatarURL: scratch.path("avatar.png"),
            preferences: UserDefaults(suiteName: "workspace-layout-\(UUID().uuidString)") ?? .standard)
        var projects: [Project] = []
        for name in ["teya-developer-portal", "infra-metadata-api",
                     "infra-cicd-tektonkustomize", "cicd-guardrail-review"] {
            let project = try TestStore.project(in: store, named: name)
            try GitRepo.run(["init", "-q", "-b", "main"], in: project.url)
            try GitRepo.run(["config", "user.email", "test@example.com"], in: project.url)
            try GitRepo.run(["config", "user.name", "Test"], in: project.url)
            try GitRepo.run(["config", "commit.gpgsign", "false"], in: project.url)
            try GitRepo.run(["commit", "-q", "--allow-empty", "-m", "start"], in: project.url)
            projects.append(project)
        }
        // A lead off its default branch and with uncommitted work puts every reading on
        // the strip at once.
        try GitRepo.run(["switch", "-q", "-c", "update-secrets-for-the-deploy-pipeline"],
                        in: projects[0].url)
        let workspace = try #require(store.addWorkspace(name: "Developer Portal",
                                                        projectIDs: projects.map(\.id),
                                                        leadProjectID: projects[0].id))

        let view = WorkspaceDetailView(workspaceID: workspace.id)
            .environment(store)
            .environment(SessionRunner(preferences: testPreferences.store, paths: [:]))
            .environment(DialogPresenter())
            .environment(TerminalStore())
            .environment(WorkingTreeWatch(inspect: { _ in 1 }))
            .environment(settings)
            .transaction { $0.disablesAnimations = true }
            .appOverlays()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.layoutIfNeeded()

        // The strip is only full once every repository has reported back, and with every
        // reading in place it wants far more room than any pane has.
        let unbounded = CGSize(width: CGFloat.infinity, height: 900)
        #expect(await waitUntil { hosting.sizeThatFits(in: unbounded).width > 1000 })

        // The smallest window is 960 points wide and the sidebar takes 318 of them.
        let pane: CGFloat = 600
        // Text and edges can round to the next backing pixel during measurement.
        let pixel = 1 / window.backingScaleFactor
        #expect(hosting.sizeThatFits(in: CGSize(width: pane, height: 900)).width <= pane + pixel)
    }
}
