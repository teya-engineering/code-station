import Foundation

// A throwaway Kiro agent profile for a run that must not change anything. A review may
// read files; an answer such as a prompt suggestion gets no tools at all.
struct KiroReviewProfile {
    let name: String
    private let file: URL

    init(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
         readsFiles: Bool = true) throws {
        let directory = AgentKind.kiro.configDirectory(environment: environment, home: home)
            .appendingPathComponent("agents")
        name = "code-station-review-" + UUID().uuidString.lowercased()
        file = directory.appendingPathComponent(name + ".json")
        // Denials win over saved allowances in every Kiro scope. The tool list also
        // keeps commands, other agents and external tools out of the run.
        let denied = ["fs_write", "shell", "mcp", "subagent", "power"] + (readsFiles ? [] : ["fs_read"])
        let profile: [String: Any] = [
            "name": name,
            "tools": readsFiles ? ["read_file", "list_directory", "file_search", "grep_search"] : [],
            "includeMcpJson": false,
            "includePowers": false,
            "mcpServers": [String: String](),
            "permissions": ["rules": (readsFiles ? [["capability": "fs_read", "effect": "allow"]] : [])
                + denied.map { ["capability": $0, "effect": "deny"] }],
        ]
        let data = try JSONSerialization.data(withJSONObject: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .withoutOverwriting)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}
