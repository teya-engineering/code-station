import Foundation

struct SiteConfigurationSelection: Sendable {
    let data: Data
    let sourceName: String
    let defaults: SiteDefaults

    var summary: String { defaults.summary }

    // What the file offers, one pickable part at a time.
    var plan: SiteConfigurationPlan { SiteConfigurationPlan(defaults) }
}

enum SiteConfigurationImporter {
    struct GitHubRepository: Equatable, Sendable {
        let owner: String
        let name: String

        init(_ input: String) throws {
            var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("github.com/") {
                value = "https://\(value)"
            }
            guard let components = URLComponents(string: value),
                  components.host?.lowercased() == "github.com",
                  components.scheme?.lowercased() == "https" else {
                throw ImportError("Enter an HTTPS GitHub repository URL, such as https://github.com/example/team-settings.")
            }

            let path = components.path.split(separator: "/").map(String.init)
            guard path.count == 2 else {
                throw ImportError("Enter the repository URL, not a link to a branch, folder, or file.")
            }
            let owner = path[0]
            let name = path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
            guard !owner.isEmpty, !name.isEmpty,
                  owner.rangeOfCharacter(from: allowed.inverted) == nil,
                  name.rangeOfCharacter(from: allowed.inverted) == nil else {
                throw ImportError("The GitHub organisation or repository name is not valid.")
            }
            self.owner = owner
            self.name = name
        }

        var cloneURL: String { "https://github.com/\(owner)/\(name).git" }
        var label: String { "\(owner)/\(name)" }
    }

    static let destination = AppPaths.support.appendingPathComponent(SiteDefaults.fileName)

    static func load(file url: URL) throws -> SiteConfigurationSelection {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError("The file could not be read: \(error.localizedDescription)")
        }
        return try selection(data: data, sourceName: url.lastPathComponent, sourceURL: url)
    }

    @MainActor
    static func load(gitHubRepository input: String) async throws -> SiteConfigurationSelection {
        let repository = try GitHubRepository(input)
        guard let git = ProcessManager.resolve("git") else {
            throw ImportError("Git is not installed or could not be found on PATH.")
        }

        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-site-configuration-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkout) }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let output: CommandRunner.Output
        do {
            output = try await CommandRunner.run(
                executable: git,
                arguments: ["clone", "--depth", "1", "--single-branch", "--",
                            repository.cloneURL, checkout.path],
                environment: environment,
                timeout: .seconds(90),
                outputByteLimit: 65_536)
        } catch {
            throw ImportError("The repository could not be loaded: \(error.localizedDescription)")
        }
        guard output.succeeded else {
            let detail = output.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let concise = String(detail.prefix(500))
            throw ImportError(detail.isEmpty
                ? "Git could not clone the repository."
                : "Git could not clone the repository: \(concise)")
        }

        let file = try configurationFile(in: checkout)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ImportError("The configuration file could not be read: \(error.localizedDescription)")
        }
        return try selection(data: data,
                             sourceName: "\(repository.label)/\(file.lastPathComponent)",
                             sourceURL: file)
    }

    @discardableResult
    static func install(_ selection: SiteConfigurationSelection) throws -> SiteDefaults {
        try write(selection.data)
    }

    // Editing keeps the document as text rather than rebuilding it from SiteDefaults.
    // That preserves fields a newer site file may carry before this build reads them.
    static func editedData(_ text: String, sourceURL: URL = destination) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError("The configuration cannot be empty. Use an empty JSON object if no shared settings are needed.")
        }
        let data = Data(text.utf8)
        _ = try selection(data: data,
                          sourceName: SiteDefaults.fileName,
                          sourceURL: sourceURL)
        return data
    }

    @discardableResult
    static func install(editedText text: String, at url: URL = destination) throws -> SiteDefaults {
        let data = try editedData(text, sourceURL: url)
        do {
            try PersistentFile.write(data, to: url)
        } catch {
            throw ImportError("The configuration could not be saved: \(error.localizedDescription)")
        }
        return SiteDefaults.reload()
    }

    // Keeping only some of a file rewrites it, so what lands on disk is the setup the app
    // is actually running rather than a document with parts of it quietly ignored. Taking
    // everything writes the file untouched, which leaves a full import byte for byte the
    // file the team published.
    @discardableResult
    static func install(_ selection: SiteConfigurationSelection,
                        keeping chosen: Set<SiteConfigurationItem>) throws -> SiteDefaults {
        guard !chosen.isEmpty else {
            throw ImportError("Choose at least one part of the configuration to use.")
        }
        guard chosen != selection.plan.everything else { return try install(selection) }
        return try write(SiteConfigurationPlan.filter(selection.data, keeping: chosen))
    }

    private static func write(_ data: Data) throws -> SiteDefaults {
        do {
            try PersistentFile.write(data, to: destination)
        } catch {
            throw ImportError("The configuration could not be saved: \(error.localizedDescription)")
        }
        Preferences.siteDefaultsURL = nil
        return SiteDefaults.reload()
    }

    static func configurationFile(in repository: URL) throws -> URL {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: repository,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw ImportError("The repository contents could not be read: \(error.localizedDescription)")
        }

        for name in [SiteDefaults.fileName, "teya-defaults.json"] {
            if let match = files.first(where: { $0.lastPathComponent == name && $0.isRegularFile }) {
                return match
            }
        }
        let json = files.filter { $0.pathExtension.lowercased() == "json" && $0.isRegularFile }
        guard json.count == 1, let file = json.first else {
            throw ImportError("The repository must contain site-defaults.json, teya-defaults.json, or exactly one JSON file in its root.")
        }
        return file
    }

    private static func selection(data: Data, sourceName: String, sourceURL: URL) throws
        -> SiteConfigurationSelection {
        do {
            let defaults = try SiteDefaults.decode(data, from: sourceURL)
            return SiteConfigurationSelection(data: data,
                                              sourceName: sourceName,
                                              defaults: defaults)
        } catch {
            throw ImportError("The configuration is not valid: \(error.localizedDescription)")
        }
    }
}

private extension URL {
    var isRegularFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
