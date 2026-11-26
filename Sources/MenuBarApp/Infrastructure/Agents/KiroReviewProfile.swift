import Foundation

struct KiroReviewProfile {
    let name: String
    private let file: URL

    init(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        var root = home.appendingPathComponent(".kiro")
        if let path = environment["KIRO_HOME"], path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            // Kiro ignores roots that contain the person's home directory.
            if candidate.path != "/", home.path != candidate.path,
               !home.path.hasPrefix(candidate.path + "/") { root = candidate }
        }
        let directory = root.appendingPathComponent("agents")
        name = "code-station-review-" + UUID().uuidString.lowercased()
        file = directory.appendingPathComponent(name + ".json")
        // Denials win over saved allowances in every Kiro scope. The tool list also
        // keeps commands, other agents and external tools out of the review.
        let profile: [String: Any] = [
            "name": name,
            "tools": ["read_file", "list_directory", "file_search", "grep_search"],
            "includeMcpJson": false,
            "includePowers": false,
            "mcpServers": [String: String](),
            "permissions": ["rules": [["capability": "fs_read", "effect": "allow"]]
                + ["fs_write", "shell", "mcp", "subagent", "power"].map {
                    ["capability": $0, "effect": "deny"]
                }],
        ]
        let data = try JSONSerialization.data(withJSONObject: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .withoutOverwriting)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}
