import Foundation

// Kiro has no plugin command, but its agent loads every `~/.kiro/skills/<name>/SKILL.md`.
// So a marketplace package reaches Kiro by copying the package's skills there. Each copy
// carries a marker naming the package it came from, which is how the installed list is
// read back and how an update or removal finds the copies, never touching a skill the
// person put there themselves. Only skills are copied: a package's agents, commands,
// hooks and MCP servers have no place in Kiro.
struct KiroSkillShelf: Sendable {
    static let markerName = ".code-station-package.json"

    struct Marker: Codable, Equatable, Sendable {
        let package: String
        let marketplace: String
        let version: String
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    let directory: URL

    static var standard: KiroSkillShelf {
        KiroSkillShelf(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/skills", isDirectory: true))
    }

    // Installed packages, keyed `package@marketplace`, for the marketplaces asked about.
    func installations(marketplaces: Set<String>) -> [String: SkillInstallation] {
        var result: [String: SkillInstallation] = [:]
        for (_, marker) in markers() where marketplaces.contains(marker.marketplace) {
            result["\(marker.package)@\(marker.marketplace)"] = SkillInstallation(
                version: marker.version, enabled: true)
        }
        return result
    }

    // Copies the package's skills in. A reinstall or update replaces the package's own
    // copies; a skill of the same name from anywhere else stops the install untouched.
    func install(package: String, marketplace: String, version: String?, from packageFolder: URL) throws {
        let files = FileManager.default
        let skillsFolder = packageFolder.appendingPathComponent("skills", isDirectory: true)
        let skills = ((try? files.contentsOfDirectory(at: skillsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { files.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !skills.isEmpty else {
            throw Failure(message: "This package has no skills Kiro can use.")
        }
        let owned = Set(markers().filter { $0.1.package == package && $0.1.marketplace == marketplace }
            .map(\.0.lastPathComponent))
        for skill in skills where !owned.contains(skill.lastPathComponent)
            && files.fileExists(atPath: directory.appendingPathComponent(skill.lastPathComponent).path) {
            throw Failure(message: "Kiro already has a skill named \(skill.lastPathComponent) from somewhere else.")
        }

        let marker = Marker(package: package, marketplace: marketplace,
                            version: version ?? Self.manifestVersion(in: packageFolder) ?? "unknown")
        let markerData = try JSONEncoder().encode(marker)
        // Staged beside the shelf, so each skill lands with one move and Kiro never reads
        // a half-copied one.
        let staging = directory.appendingPathComponent(".code-station-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        for skill in skills {
            let copy = staging.appendingPathComponent(skill.lastPathComponent, isDirectory: true)
            try files.copyItem(at: skill, to: copy)
            try markerData.write(to: copy.appendingPathComponent(Self.markerName))
        }
        try remove(package: package, marketplace: marketplace)
        for skill in skills {
            try files.moveItem(at: staging.appendingPathComponent(skill.lastPathComponent),
                               to: directory.appendingPathComponent(skill.lastPathComponent))
        }
    }

    func remove(package: String, marketplace: String) throws {
        for (folder, marker) in markers() where marker.package == package && marker.marketplace == marketplace {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func markers() -> [(URL, Marker)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.markerName)),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
            return (folder, marker)
        }
    }

    private static func manifestVersion(in packageFolder: URL) -> String? {
        for path in [".claude-plugin/plugin.json", "plugin.json"] {
            guard let data = try? Data(contentsOf: packageFolder.appendingPathComponent(path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? String, !version.isBlank else { continue }
            return version
        }
        return nil
    }

    // Where a package's files sit inside the marketplace's own copy. Only a package kept
    // in the marketplace's repository can be copied; one fetched from elsewhere cannot.
    static func packageFolder(source: String?, marketplaceRoot: URL) throws -> URL {
        guard let source, !source.isBlank, !source.contains("://"), !source.hasPrefix("/") else {
            throw Failure(message: "Kiro can only take packages kept in the marketplace's own repository.")
        }
        let folder = marketplaceRoot.appendingPathComponent(source, isDirectory: true).standardizedFileURL
        guard folder.path.hasPrefix(marketplaceRoot.standardizedFileURL.path + "/") else {
            throw Failure(message: "Kiro can only take packages kept in the marketplace's own repository.")
        }
        return folder
    }
}
