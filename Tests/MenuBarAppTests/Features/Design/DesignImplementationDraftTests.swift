import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct DesignImplementationDraftTests {
    private let preferences = TestPreferences()
    private let scratch: ScratchDirectory
    private let store: ProjectStore
    private let session: ChatSession
    private let catalog: AgentCatalog

    init() throws {
        (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let created = store.newSession(in: project.id, seed: .init(agent: .codex, model: "gpt-5.6-sol", mode: .design))
        store.setSettings(SessionSettings(model: "gpt-5.6-sol", effort: "high", codexSandboxMode: .workspaceWrite), for: created.id)
        session = try #require(store.session(created.id))
        catalog = AgentCatalog(paths: [.codex: "/codex", .claudeCode: "/claude", .copilot: "/copilot"],
                               preferences: preferences.store)
        catalog.setDefaults(SessionSettings(model: "sonnet", effort: "medium", permissionMode: .manual), for: .claudeCode)
        catalog.setDefaults(SessionSettings(model: "auto", effort: "low", copilotAccessMode: .workspace), for: .copilot)
    }

    @Test func disclosureAndReopeningKeepTheInheritedSettingsAndGuidance() {
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.text = "Keep the navigation."
        draft.isExpanded = true
        draft.isExpanded = false
        draft.reopen()
        #expect(draft.isInherited)
        #expect(!draft.isExpanded)
        #expect(draft.settings == session.settings)
        #expect(draft.text == "Keep the navigation.")
        #expect(draft.summaryTitle == "Same agent as the design session")
        #expect(draft.summaryDetail == "Codex, with the same model, effort and permissions.")
    }

    @Test func eachProviderKeepsItsOwnDraftWithoutTranslatingPermissions() throws {
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.edit { $0.codexSandboxMode = .fullAccess }
        draft.chooseAgent(.claudeCode)
        #expect(draft.model == "sonnet")
        #expect(draft.effort == "medium")
        #expect(draft.permission == .manual)
        #expect(draft.settings.codexSandboxMode == nil)
        draft.chooseModel("opus")
        draft.edit { $0.permissionMode = .plan; $0.effort = "max" }
        draft.chooseAgent(.copilot)
        #expect(draft.copilotAccess == .workspace)
        #expect(draft.settings.permissionMode == nil)
        draft.edit { $0.copilotAccessMode = .fullAccess }
        draft.chooseAgent(.codex)
        #expect(draft.codexAccess == .fullAccess)
        #expect(draft.model == "gpt-5.6-sol")
        draft.chooseAgent(.claudeCode)
        #expect(draft.model == "opus")
        #expect(draft.effort == "max")
        #expect(draft.permission == .plan)
        let selected = try #require(draft.start())
        #expect(selected.settings.codexSandboxMode == nil)
        #expect(selected.settings.copilotAccessMode == nil)
        #expect(store.session(session.id)?.settings == session.settings)
        #expect(catalog.defaults(for: .claudeCode).permissionMode == .manual)
    }

    @Test func customSummariesAndResetReflectAllFourChoices() {
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.text = "Keep me."
        draft.edit { $0.effort = "low"; $0.codexSandboxMode = .approveForMe }
        #expect(draft.summaryTitle == "Codex with custom settings")
        #expect(draft.summaryDetail == "Sol, low effort, Sandboxed + auto.")
        draft.chooseAgent(.claudeCode)
        #expect(draft.summaryTitle == "Implement with Claude Code")
        #expect(draft.summaryDetail == "Sonnet, medium effort, Every step.")
        draft.isExpanded = true
        draft.reset()
        #expect(draft.isInherited)
        #expect(draft.settings == session.settings)
        #expect(!draft.isExpanded)
        #expect(draft.text == "Keep me.")
    }

    @Test func modelChangesAndDiscoveredCapabilitiesResetIncompatibleEffort() {
        let catalog = AgentCatalog(paths: [.codex: "/codex"], discoveredModels: [.codex: [
            .init(id: "gpt-5.6-sol", title: "Sol", detail: "", supportedEfforts: ["low", "high"], isDefault: true),
            .init(id: "limited", title: "Limited", detail: "", supportedEfforts: ["low", "medium"]),
            .init(id: "lowest", title: "Lowest", detail: "", supportedEfforts: ["low"])
        ]], preferences: preferences.store)
        catalog.setDefaults(SessionSettings(effort: "medium"), for: .codex)
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.chooseModel("limited")
        #expect(draft.settings.effort == nil)
        #expect(draft.effort == "medium")
        #expect(draft.effortLevels == ["low", "medium"])
        #expect(draft.effortAdjustment == "Effort reset to Default. Limited does not support high effort.")
        draft.edit { $0.effort = "medium" }
        draft.chooseModel("lowest")
        #expect(draft.settings.effort == nil)
        #expect(draft.effort == nil)
        #expect(draft.effortTitle == "Default")
    }

    @Test func codeStationModelDefaultIsResolvedBeforeHandoff() throws {
        catalog.setDefaults(SessionSettings(model: "gpt-5.6-terra", effort: "low", codexSandboxMode: .approveForMe), for: .codex)
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.chooseModel(nil, useDefault: true)
        draft.edit { $0.effort = nil; $0.codexSandboxMode = nil }
        #expect(draft.summaryDetail == "Terra, low effort, Sandboxed + auto.")
        let selection = try #require(draft.start())
        let launch = AgentLaunchConfiguration(agent: selection.agent, settings: selection.settings,
                                             defaults: catalog.defaults(for: selection.agent))
        #expect(launch.model == "gpt-5.6-terra")
        #expect(launch.effort == "low")
        #expect(launch.codexSandbox == .approveForMe)
    }

    @Test func failureKeepsTheDraftAndExpansionAndUnlocksRetry() throws {
        let draft = DesignImplementationDraft(session: session, catalog: catalog)
        draft.isExpanded = true
        draft.text = "Additional guidance"
        draft.chooseAgent(.copilot)
        let first = try #require(draft.start())
        #expect(!draft.canStart)
        #expect(draft.start() == nil)
        draft.chooseAgent(.claudeCode)
        draft.reset()
        draft.edit { $0.effort = "high" }
        #expect(draft.agent == .copilot)
        #expect(draft.isExpanded)
        let failure = DesignHandoffLifecycle.Failure(title: "Could not start", message: "Could not save the reference.")
        draft.finish(failure)
        #expect(draft.failure == failure)
        #expect(draft.text == "Additional guidance")
        #expect(draft.isExpanded)
        #expect(draft.canStart)
        #expect(draft.start() == first)
        #expect(draft.failure == nil)
    }

    @Test func missingAgentsCannotSubmitOrSilentlySwitchProvider() {
        let empty = AgentCatalog(paths: [:], preferences: preferences.store)
        let draft = DesignImplementationDraft(session: session, catalog: empty)
        #expect(draft.summaryTitle == "No agents available")
        #expect(draft.start() == nil)
        let other = AgentCatalog(paths: [.claudeCode: "/claude"], preferences: preferences.store)
        let unavailable = DesignImplementationDraft(session: session, catalog: other)
        #expect(unavailable.summaryTitle == "Codex is unavailable")
        #expect(unavailable.start() == nil)
        unavailable.chooseAgent(.claudeCode)
        #expect(unavailable.canStart)
    }
}
