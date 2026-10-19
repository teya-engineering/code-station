import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct FirstRunSetupTests {
    private let testPreferences = TestPreferences()
    @Test func keepsTheExistingAgentChoiceAndStartsWithConnection() {
        let setup = FirstRunSetup(initialAgent: .copilot)
        #expect(setup.selectedAgent == .copilot)
        #expect(setup.step == .agent)
    }

    @Test(arguments: [AgentReadiness.notInstalled, .checking, .signInNeeded, .failed])
    func anUnreadyAgentCanOnlyAdvanceByDeferring(_ readiness: AgentReadiness) {
        let setup = FirstRunSetup(initialAgent: .codex)
        setup.continueFromAgent(readiness: readiness)
        #expect(setup.step == .agent)
        setup.continueFromAgent(readiness: readiness, deferSetup: true)
        #expect(setup.step == .configuration)
        #expect(setup.agentWasDeferred)
        setup.step = .agent
        setup.continueFromAgent(readiness: .connected)
        #expect(setup.step == .configuration)
        #expect(!setup.agentWasDeferred)
    }

    @Test func personalSetupContinuesWithoutApplyingALoadedFile() throws {
        let scratch = ScratchDirectory()
        let setup = FirstRunSetup(initialAgent: .claudeCode)
        try loadSettings(into: setup, in: scratch)
        setup.step = .configuration
        #expect(setup.canContinueConfiguration)
        setup.continueFromConfiguration(install: { _ in Issue.record("Personal setup must not import") },
                                        didInstall: { Issue.record("Nothing was installed") })
        #expect(setup.step == .project)
        #expect(setup.appliedConfiguration == nil)
    }

    @Test func teamSetupNeedsAFileAndACompleteLoad() async {
        let setup = FirstRunSetup(initialAgent: .codex)
        setup.step = .configuration
        setup.usesTeamSettings = true
        #expect(!setup.canContinueConfiguration)
        setup.loader.repositoryURL = "not a repository"
        setup.loader.loadRepository()
        #expect(!setup.canContinueConfiguration)
        #expect(await waitUntil { !setup.loader.isLoading })
        #expect(setup.loader.failure != nil)
        setup.continueFromConfiguration(didInstall: { Issue.record("No valid file") })
        #expect(setup.step == .configuration)
    }

    @Test func installationFailureStaysOnTeamSetupAndCanBeRetried() throws {
        let scratch = ScratchDirectory()
        let setup = FirstRunSetup(initialAgent: .codex)
        try loadSettings(into: setup, in: scratch)
        setup.usesTeamSettings = true
        setup.step = .configuration
        let destination = scratch.path("blocked/settings.json")
        try Data("not a folder".utf8).write(to: scratch.path("blocked"))
        var applications = 0
        let install: (SiteConfigurationSelection) throws -> Void = {
            try SiteConfigurationImporter.install($0.defaults, at: destination)
        }

        setup.continueFromConfiguration(install: install, didInstall: { applications += 1 })
        #expect(setup.step == .configuration)
        #expect(setup.loader.selection != nil)
        #expect(setup.loader.failure != nil)
        #expect(setup.appliedConfiguration == nil)
        #expect(applications == 0)

        try FileManager.default.removeItem(at: scratch.path("blocked"))
        setup.continueFromConfiguration(install: install, didInstall: { applications += 1 })
        #expect(setup.step == .project)
        #expect(setup.loader.failure == nil)
        #expect(setup.appliedConfiguration == setup.loader.selection)
        #expect(applications == 1)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        setup.step = .configuration
        setup.continueFromConfiguration(install: { _ in Issue.record("Already installed") },
                                        didInstall: { applications += 1 })
        #expect(setup.step == .project)
        #expect(applications == 1)
    }

    @Test func replacingALoadedFileWithInvalidJSONDoesNotKeepTheOldSelection() throws {
        let scratch = ScratchDirectory()
        let setup = FirstRunSetup(initialAgent: .codex)
        try loadSettings(into: setup, in: scratch)
        setup.usesTeamSettings = true
        let invalid = scratch.path("invalid.json")
        try Data("invalid".utf8).write(to: invalid)
        setup.loader.loadFile(invalid)
        #expect(setup.loader.selection == nil)
        #expect(setup.loader.failure != nil)
        #expect(!setup.canContinueConfiguration)
    }

    @Test func finishingOpensTheProjectWithoutStartingWork() throws {
        try withStore { store, scratch in
            let repository = try GitRepo()
            let setup = FirstRunSetup(initialAgent: .codex)
            setup.projectURL = repository.url
            let originalHead = try repository.git("rev-parse", "HEAD")
            let originalWorktrees = try repository.git("worktree", "list", "--porcelain")
            #expect(store.projects.isEmpty)
            #expect(setup.finish(in: store, openProject: true))
            let project = try #require(store.projects.first)
            #expect(store.selectedProjectID == project.id)
            #expect(store.selection == nil)
            #expect(store.navigation.projectToReveal == project.id)
            #expect(store.sessions.isEmpty)
            #expect(try repository.git("rev-parse", "HEAD") == originalHead)
            #expect(try repository.git("worktree", "list", "--porcelain") == originalWorktrees)
            #expect(try repository.git("status", "--porcelain").isEmpty)
            #expect(ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json")).projects.count == 1)
        }
    }

    @Test func anExistingFolderSelectsItsProjectWithoutOpeningASession() throws {
        try withStore { store, scratch in
            let project = try #require(store.addProject(at: scratch.url))
            let session = store.newSession(in: project.id)
            store.selectSession(session.id)
            let setup = FirstRunSetup(initialAgent: .codex)
            setup.projectURL = scratch.url
            #expect(setup.finish(in: store, openProject: true))
            #expect(store.projects.count == 1)
            #expect(store.sessions.count == 1)
            #expect(store.selectedProjectID == project.id)
            #expect(store.selection == nil)
        }
    }

    @Test func skippingASelectedFolderFinishesOnHomeWithoutAddingIt() throws {
        try withStore { store, scratch in
            let setup = FirstRunSetup(initialAgent: .codex)
            setup.projectURL = scratch.url
            #expect(setup.finish(in: store, openProject: false))
            #expect(store.projects.isEmpty)
            #expect(store.selection == .home)
        }
    }

    @Test func aMissingFolderKeepsTheWizardOpen() throws {
        try withStore { store, scratch in
            let setup = FirstRunSetup(initialAgent: .codex)
            setup.projectURL = scratch.path("missing")
            #expect(!setup.finish(in: store, openProject: true))
            #expect(setup.projectFailure != nil)
            #expect(store.projects.isEmpty)
        }
    }

    @Test func aFailedProjectSaveCanBeRetriedWithoutDuplicatingTheProject() throws {
        try withStore { _, scratch in
            let blocked = scratch.path("blocked")
            let store = ProjectStore(preferences: testPreferences.store, storeURL: blocked.appendingPathComponent("projects.json"))
            try Data("not a folder".utf8).write(to: blocked)
            let setup = FirstRunSetup(initialAgent: .codex)
            setup.projectURL = scratch.url
            #expect(!setup.finish(in: store, openProject: true))
            #expect(setup.projectFailure != nil)
            try FileManager.default.removeItem(at: blocked)
            #expect(setup.finish(in: store, openProject: true))
            #expect(setup.projectFailure == nil)
            #expect(store.projects.count == 1)
        }
    }

    private func loadSettings(into setup: FirstRunSetup, in scratch: ScratchDirectory) throws {
        let file = scratch.path("site-defaults.json")
        try Data(#"{"shortcuts":[{"name":"Test","command":"make test"}]}"#.utf8).write(to: file)
        setup.loader.loadFile(file)
        #expect(setup.loader.failure == nil)
    }

    private func withStore(_ body: (ProjectStore, ScratchDirectory) throws -> Void) throws {
        let scratch = ScratchDirectory(prefix: "first-run")
        let store = ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json"))
        try body(store, scratch)
    }
}
