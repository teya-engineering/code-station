import Foundation
import Testing
@testable import MenuBarApp

struct SecondOpinionLaunchTests {
    @Test(arguments: ["success", "failure", "timeout"])
    func kiroUsesAReadOnlyProfileAndRemovesItAfterTheRun(_ outcome: String) async throws {
        let scratch = ScratchDirectory(prefix: "kiro-review")
        let agents = scratch.path(".kiro/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let existing = agents.appendingPathComponent("personal.json")
        let personal = #"{"name":"personal","tools":["*"],"permissions":{"rules":[{"capability":"all","effect":"allow"}]}}"#
        try personal.write(to: existing, atomically: true, encoding: .utf8)
        let executable = scratch.path("kiro-cli")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" > review-arguments
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --agent ]; then
                cp ".kiro/agents/$2.json" observed-profile.json || exit 8
                break
            fi
            shift
        done
        [ -f observed-profile.json ] || exit 9
        \#(outcome == "timeout" ? "exec /bin/sleep 30" : "")
        printf '[]\n'
        exit \#(outcome == "failure" ? 7 : 0)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = await SecondOpinion.run(
            agent: .kiro, executable: executable.path, searchPath: "/usr/bin:/bin", directory: scratch.url.path,
            timeout: outcome == "timeout" ? .seconds(1) : .seconds(30), writing: "Reviewing",
            environment: ["KIRO_HOME": scratch.path(".kiro").path], activity: { _ in }) { _, _ in
                SecondOpinion.arguments(for: .kiro, prompt: "Review this code")
            }
        if outcome == "success" { #expect(result == .success("[]\n")) }
        else if case .success = result { Issue.record("Expected the run to fail") }
        let arguments = try String(contentsOf: scratch.path("review-arguments"), encoding: .utf8)
        #expect(arguments.contains("--agent-engine\nv3\n"))
        #expect(arguments.contains("--no-interactive\n"))
        #expect(!arguments.contains("--trust"))
        let profile = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: scratch.path("observed-profile.json"))) as? [String: Any])
        let name = try #require(profile["name"] as? String)
        #expect(arguments.contains("--agent\n\(name)\n"))
        #expect(profile["tools"] as? [String] == ["read_file", "list_directory", "file_search", "grep_search"])
        #expect(profile["includeMcpJson"] as? Bool == false)
        #expect(profile["includePowers"] as? Bool == false)
        let rules = try #require((profile["permissions"] as? [String: Any])?["rules"] as? [[String: String]])
        #expect(rules.contains(["capability": "fs_read", "effect": "allow"]))
        for capability in ["fs_write", "shell", "mcp", "subagent", "power"] {
            #expect(rules.contains(["capability": capability, "effect": "deny"]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: agents.path) == ["personal.json"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == personal)
    }

    @Test func kiroDoesNotStartWhenItsReadOnlyProfileCannotBeCreated() async throws {
        let scratch = ScratchDirectory(prefix: "kiro-review")
        let blocked = scratch.path("agents")
        try Data().write(to: blocked)
        let executable = try agent(in: scratch, listing: "[]")
        let result = await SecondOpinion.run(
            agent: .kiro, executable: executable, searchPath: "/usr/bin:/bin", directory: scratch.url.path,
            timeout: .seconds(30), writing: "Reviewing",
            environment: ["KIRO_HOME": blocked.path], activity: { _ in }) { _, _ in
                SecondOpinion.arguments(for: .kiro, prompt: "Review this code")
            }
        if case .success = result { Issue.record("Expected profile creation to fail") }
        #expect(!FileManager.default.fileExists(atPath: scratch.path("review-arguments").path))
    }

    @Test func codexListsServersInTheReviewDirectoryAndDisablesThemBeforeRunning() async throws {
        let scratch = ScratchDirectory(prefix: "second-opinion")
        let executable = try agent(in: scratch, listing: #"[{"name":"files","enabled":true,"transport":{"command":"files-server"}},{"name":"remote","enabled":true,"transport":{"url":"https://example.com/mcp"}}]"#)
        let result = await SecondOpinion.review([], reviewer: .init(agent: .codex), executable: executable,
                                                searchPath: "/usr/bin:/bin", repositories: [
                                                    (root: scratch.url.path, name: "App"),
                                                    (root: "/attached/project", name: "API")
                                                ])
        #expect(result == .success([]))
        let directory = try String(contentsOf: scratch.path("discovery-directory"), encoding: .utf8).trimmed
        #expect(URL(fileURLWithPath: directory).resolvingSymlinksInPath() == scratch.url.resolvingSymlinksInPath())
        let arguments = try String(contentsOf: scratch.path("review-arguments"), encoding: .utf8)
        #expect(arguments.contains("--sandbox\nread-only\n"))
        #expect(arguments.contains(#"mcp_servers={"files"={enabled=false,command="/usr/bin/false"},"remote"={enabled=false,url="https://disabled.invalid"}}"#))
        #expect(arguments.contains("- API: /attached/project"))
    }

    @Test(arguments: ["command failed", "invalid JSON", "unknown transport", "empty name", "truncated"])
    func codexDoesNotStartWhenServerDiscoveryIsIncomplete(_ failure: String) async throws {
        let scratch = ScratchDirectory(prefix: "second-opinion")
        let listing = switch failure {
        case "command failed": "[]"
        case "unknown transport": #"[{"name":"unknown","enabled":true,"transport":{}}]"#
        case "empty name": #"[{"name":"","enabled":true,"transport":{"command":"server"}}]"#
        case "truncated": String(repeating: " ", count: 1_048_576) + "[]"
        default: "invalid JSON"
        }
        let executable = try agent(in: scratch, listing: listing, status: failure == "command failed" ? 1 : 0)
        let result = await SecondOpinion.review([], reviewer: .init(agent: .codex), executable: executable,
                                                searchPath: "/usr/bin:/bin",
                                                repositories: [(root: scratch.url.path, name: "App")])
        #expect(result == .failure(.init(message: "Could not list Codex's MCP servers to disable them.")))
        #expect(!FileManager.default.fileExists(atPath: scratch.path("review-arguments").path))
    }

    @Test func codexCanReviewWhenNoServersAreConfigured() async throws {
        let scratch = ScratchDirectory(prefix: "second-opinion")
        let executable = try agent(in: scratch, listing: "[]")
        let result = await SecondOpinion.review([], reviewer: .init(agent: .codex), executable: executable,
                                                searchPath: "/usr/bin:/bin",
                                                repositories: [(root: scratch.url.path, name: "App")])
        #expect(result == .success([]))
    }

    private func agent(in scratch: ScratchDirectory, listing: String, status: Int = 0) throws -> String {
        let executable = scratch.path("agent")
        let script = #"""
        #!/bin/sh
        if [ "$1" = mcp ]; then
            pwd -P > discovery-directory
            cat <<'SERVERS'
        \#(listing)
        SERVERS
            exit \#(status)
        fi
        printf '%s\n' "$@" > review-arguments
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"[]"}}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable.path
    }
}
