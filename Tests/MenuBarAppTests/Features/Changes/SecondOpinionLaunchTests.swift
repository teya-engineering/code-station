import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct SecondOpinionLaunchTests {
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
