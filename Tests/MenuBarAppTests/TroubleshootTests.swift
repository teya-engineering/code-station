import Foundation
import Testing
@testable import MenuBarApp

struct TroubleshootTests {
    @Test func promptCarriesTheProblemAndSelectedContext() {
        let request = TroubleshootRequest(
            problem: "Payments return 503 after deployment",
            environment: .prod,
            projects: ["payments-api", "merchant-web"],
            mcpServersEnabled: true)

        #expect(request.prompt.contains("Payments return 503 after deployment"))
        #expect(request.prompt.contains("production (prod)"))
        #expect(request.prompt.contains("payments-api, merchant-web"))
        #expect(request.prompt.contains("MCP servers are enabled"))
        #expect(request.prompt.contains("do not mutate data, configuration, deployments, or running services"))
        #expect(request.prompt.contains("wait for a follow-up before applying it"))
    }

    @Test func attachmentOnlyDiagnosisStillHasAnInstruction() {
        let request = TroubleshootRequest(
            problem: "  \n",
            environment: .dev,
            projects: ["api"],
            mcpServersEnabled: false)

        #expect(request.prompt.hasPrefix("Troubleshoot the problem shown in the attached files."))
        #expect(request.prompt.contains("MCP servers are disabled for this diagnosis"))
    }

    @Test func claudeRunsWithOnlyAnEmptyMCPConfigurationWhenDisabled() {
        let arguments = SessionRunner.arguments(
            settings: SessionSettings(mcpServersEnabled: false),
            defaults: SessionSettings(permissionMode: "acceptEdits"))

        #expect(pair(arguments, after: "--mcp-config") == #"{"mcpServers":{}}"#)
        #expect(arguments.contains("--strict-mcp-config"))
    }

    @Test func codexDisablesEveryServerInTheDiagnosisSnapshot() {
        let settings = SessionSettings(
            mcpServersEnabled: false,
            disabledMCPServerNames: ["grafana-platform-dev", "node_repl"])
        let arguments = SessionRunner.arguments(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings())

        #expect(arguments.contains("mcp_servers.grafana-platform-dev.enabled=false"))
        #expect(arguments.contains("mcp_servers.node_repl.enabled=false"))
    }

    private func pair(_ arguments: [String], after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

@MainActor
struct TroubleshootProjectTests {
    @Test func filtersProjectsByNameOrPathIgnoringCase() {
        let api = Project(name: "Payments API", path: "/Development/services/payments-api")
        let web = Project(name: "Merchant Web", path: "/Development/frontends/merchant-web")

        #expect(TroubleshootView.projects([api, web], matching: "PAYMENTS") == [api])
        #expect(TroubleshootView.projects([api, web], matching: "frontends") == [web])
        #expect(TroubleshootView.projects([api, web], matching: "  ") == [api, web])
    }

    @Test func multiProjectDiagnosisUsesAttachedRootsWithoutSavingAWorkspace() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-troubleshoot-tests-\(UUID().uuidString).json")
        setenv("CONDUCTOR_STORE", storeURL.path, 1)
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(
                at: storeURL.deletingLastPathComponent()
                    .appendingPathComponent(storeURL.deletingPathExtension().lastPathComponent
                        + "-transcripts"))
        }

        let store = ProjectStore()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("payments-api-\(UUID().uuidString)")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merchant-web-\(UUID().uuidString)")
        let first = try #require(store.addProject(at: firstURL))
        let second = try #require(store.addProject(at: secondURL))

        let session = try #require(store.newSession(in: [first.id, second.id]))

        #expect(session.projectID == first.id)
        #expect(session.workspaceID == nil)
        #expect(store.workspaces.isEmpty)
        #expect(store.workingDirectories(for: session) == [first.path, second.path])
        #expect(store.selection == .session(session.id))
    }
}
