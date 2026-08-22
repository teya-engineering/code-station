import Foundation

struct SiteConfigurationSelection: Sendable {
    let sourceName: String
    let defaults: SiteDefaults

    var summary: String { defaults.summary }

    // What the file offers, one independently resettable aspect at a time.
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
        try install(selection.defaults)
    }

    static func configurationData(for defaults: SiteDefaults) throws -> Data {
        // Environments always have a resolved value in the app. Materialising that value
        // keeps an export from claiming there are none while the UI offers its built-ins.
        var current = defaults
        current.environments = defaults.deployEnvironments
        current.dispatch?.environments = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(current)
            data.append(0x0A)
            return data
        } catch {
            throw ImportError("The configuration could not be encoded: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func install(_ defaults: SiteDefaults, at url: URL = destination) throws -> SiteDefaults {
        let data = try configurationData(for: defaults)
        do {
            try PersistentFile.write(data, to: url)
        } catch {
            throw ImportError("The configuration could not be saved: \(error.localizedDescription)")
        }
        let written = try SiteDefaults.decode(data, from: url)
        if url.standardizedFileURL == destination.standardizedFileURL {
            Preferences.siteDefaultsURL = nil
            return SiteDefaults.setCurrent(written, sourceURL: url)
        }
        return written
    }

    // Resetting imports selected aspects into the current document. The parts that were
    // not selected are encoded beside them unchanged, so the file on disk is always the
    // complete configuration the app is using and can be exported as-is.
    @discardableResult
    static func reset(_ selection: SiteConfigurationSelection,
                      aspects chosen: Set<SiteConfigurationAspect>,
                      current: SiteDefaults = .current,
                      at url: URL = destination) throws -> SiteDefaults {
        guard !chosen.isEmpty else {
            throw ImportError("Choose at least one aspect to reset.")
        }
        let offered = selection.plan.everything
        guard chosen.isSubset(of: offered) else {
            throw ImportError("The file does not contain every selected aspect.")
        }
        let reset = SiteConfigurationPlan.resetting(chosen,
                                                    in: current,
                                                    to: selection.defaults)
        return try install(reset, at: url)
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
            return SiteConfigurationSelection(sourceName: sourceName,
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
