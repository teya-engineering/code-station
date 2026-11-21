import Foundation

extension SkillsManager {
    // MARK: - Marketplace catalogue

    struct CatalogueLoad: Sendable {
        let marketplace: SkillMarketplace?
        let notice: String?
        let didRefresh: Bool
        // The clone stopped at a sign-in. Its message is already the notice; the screen
        // that started the clone also uses it to offer the SSH address.
        var signIn: GitSignInRequired? = nil
    }

    nonisolated static func decodeMarketplace(_ data: Data) throws -> SkillMarketplace {
        try JSONDecoder().decode(SkillMarketplace.self, from: data)
    }

    nonisolated static func localConfiguration(at url: URL) throws
        -> (SkillMarketplaceConfiguration, SkillMarketplace) {
        let url = url.standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError("The marketplace file could not be read: \(error.localizedDescription)")
        }

        let marketplace: SkillMarketplace
        do {
            marketplace = try decodeMarketplace(data)
        } catch {
            throw ImportError("The marketplace file is not valid: \(error.localizedDescription)")
        }
        guard !marketplace.name.isBlank else {
            throw ImportError("The marketplace file must contain a name.")
        }
        return (SkillMarketplaceConfiguration(source: url.path,
                                               sourceKind: .localFile,
                                               marketplace: marketplace.name,
                                               label: marketplace.name),
                marketplace)
    }

    nonisolated static func loadCachedCatalogue(
        configuration: SkillMarketplaceConfiguration?,
        at cacheURL: URL
    ) -> CatalogueLoad {
        guard let configuration else {
            return CatalogueLoad(marketplace: nil, notice: nil, didRefresh: false)
        }
        let manifest = configuration.isLocalFile
            ? URL(fileURLWithPath: configuration.source)
            : cacheURL.appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: manifest),
              let marketplace = try? decodeMarketplace(data) else {
            return CatalogueLoad(marketplace: nil, notice: nil, didRefresh: false)
        }
        return CatalogueLoad(marketplace: marketplace, notice: nil, didRefresh: false)
    }

    nonisolated static func loadCatalogue(
        configuration: SkillMarketplaceConfiguration?,
        at cacheURL: URL
    ) async -> CatalogueLoad {
        guard let configuration else {
            return CatalogueLoad(marketplace: nil,
                                 notice: "No skills marketplace is set up.",
                                 didRefresh: false)
        }

        if configuration.isLocalFile {
            let url = URL(fileURLWithPath: configuration.source)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                return CatalogueLoad(
                    marketplace: nil,
                    notice: "The marketplace file could not be read: \(error.localizedDescription)",
                    didRefresh: false)
            }
            do {
                return CatalogueLoad(marketplace: try decodeMarketplace(data),
                                     notice: nil,
                                     didRefresh: true)
            } catch {
                return CatalogueLoad(
                    marketplace: nil,
                    notice: "The marketplace file is not valid: \(error.localizedDescription)",
                    didRefresh: false)
            }
        }

        return await loadGitCatalogue(source: configuration.source, at: cacheURL)
    }

    nonisolated static func loadGitCatalogue(source: String,
                                             at cacheURL: URL,
                                             forceClone: Bool = false) async
        -> CatalogueLoad {
        let files = FileManager.default
        let manifest = cacheURL.appendingPathComponent(".claude-plugin/marketplace.json")
        let gitFolder = cacheURL.appendingPathComponent(".git")

        if !forceClone, files.fileExists(atPath: gitFolder.path) {
            let pulled = await run("git", ["-C", cacheURL.path, "pull", "--ff-only"])
            guard let data = try? Data(contentsOf: manifest),
                  let marketplace = try? decodeMarketplace(data) else {
                let detail = pulled.ok
                    ? "The repository did not contain a readable .claude-plugin/marketplace.json file."
                    : gitFailureMessage(pulled, source: source)
                return CatalogueLoad(marketplace: nil, notice: detail, didRefresh: false)
            }
            return CatalogueLoad(
                marketplace: marketplace,
                notice: pulled.ok ? nil
                    : "Could not refresh the marketplace. Showing the cached list. \(gitFailureMessage(pulled, source: source))",
                didRefresh: pulled.ok)
        }

        let parent = cacheURL.deletingLastPathComponent()
        let candidate = parent.appendingPathComponent(
            ".marketplace-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return CatalogueLoad(marketplace: nil,
                                 notice: error.localizedDescription,
                                 didRefresh: false)
        }

        let cloned = await run("git", ["clone", "--depth", "1", "--", source,
                                       candidate.path])
        guard cloned.ok else {
            try? files.removeItem(at: candidate)
            let signIn = GitSignIn.problem(in: cloned.failureMessage, address: source)
            return CatalogueLoad(marketplace: nil,
                                 notice: signIn?.message ?? cloned.failureMessage,
                                 didRefresh: false,
                                 signIn: signIn)
        }

        let candidateManifest = candidate
            .appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: candidateManifest),
              let marketplace = try? decodeMarketplace(data) else {
            try? files.removeItem(at: candidate)
            return CatalogueLoad(
                marketplace: nil,
                notice: "The repository did not contain a readable .claude-plugin/marketplace.json file.",
                didRefresh: false)
        }

        do {
            if files.fileExists(atPath: cacheURL.path) {
                try files.removeItem(at: cacheURL)
            }
            try files.moveItem(at: candidate, to: cacheURL)
            return CatalogueLoad(marketplace: marketplace, notice: nil, didRefresh: true)
        } catch {
            try? files.removeItem(at: candidate)
            return CatalogueLoad(marketplace: nil,
                                 notice: error.localizedDescription,
                                 didRefresh: false)
        }
    }

    // MARK: - Installed plugins

    struct InstallationLoad: Sendable {
        let installations: [String: SkillInstallation]
        let failure: String?
    }

    nonisolated static func installedPlugins(from output: String, for host: SkillHost,
                                             marketplace: String)
        -> [String: SkillInstallation] {
        let installations = installedPlugins(from: output, for: host, marketplaces: [marketplace])
        let suffix = "@\(marketplace)"
        return Dictionary(uniqueKeysWithValues: installations.map {
            (String($0.key.dropLast(suffix.count)), $0.value)
        })
    }

    nonisolated static func installedPlugins(from output: String, for host: SkillHost,
                                             marketplaces: Set<String>) -> [String: SkillInstallation] {
        guard let root = jsonObject(from: output) else { return [:] }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let installed = object["installed"] as? [[String: Any]] {
            rows = installed
        } else if let object = root as? [String: Any],
                  let configured = object["plugins"] as? [[String: Any]] {
            rows = configured
        } else {
            return [:]
        }

        var result: [String: SkillInstallation] = [:]
        for row in rows {
            // Copilot lists every kind of thing it has configured in one array; only the
            // plugins are the marketplace's, and each names its marketplace as a source.
            if host == .copilot, row["kind"] as? String != "plugin" { continue }
            let identifier = row["pluginId"] as? String ?? row["id"] as? String ?? ""
            let pieces = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            let name = row["name"] as? String ?? pieces.first ?? ""
            let marketplaceName = row["marketplaceName"] as? String
                ?? (row["source"] as? String).flatMap { source in
                    source.hasPrefix("marketplace:") ? String(source.dropFirst("marketplace:".count)) : nil
                }
                ?? (pieces.count == 2 ? pieces[1] : "")
            guard !name.isEmpty, marketplaces.contains(marketplaceName) else { continue }
            if host == .claude, let scope = row["scope"] as? String, scope != "user" { continue }
            if let installed = row["installed"] as? Bool, !installed { continue }

            result["\(name)@\(marketplaceName)"] = SkillInstallation(
                version: row["version"] as? String ?? "unknown",
                enabled: row["enabled"] as? Bool ?? true)
        }
        return result
    }

    // Copilot prints its marketplaces as a bulleted list rather than as JSON, one per
    // line with the name before the source in brackets.
    nonisolated static func marketplaceNames(from output: String) -> Set<String> {
        guard let root = jsonObject(from: output) else {
            let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.first, "•◆*-".contains(first) else { return nil }
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                guard let open = rest.firstIndex(of: "(") else { return nil }
                let name = rest[..<open].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            return Set(names)
        }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any],
                  let marketplaces = object["marketplaces"] as? [[String: Any]] {
            rows = marketplaces
        } else {
            return []
        }
        return Set(rows.compactMap { $0["name"] as? String })
    }

    nonisolated static func loadInstallations(marketplaces: Set<String>) async
        -> [SkillHost: InstallationLoad] {
        await withTaskGroup(of: (SkillHost, InstallationLoad).self) { group in
            for host in SkillHost.allCases {
                group.addTask { (host, await loadInstallations(for: host, marketplaces: marketplaces)) }
            }
            var loads: [SkillHost: InstallationLoad] = [:]
            for await (host, load) in group { loads[host] = load }
            return loads
        }
    }

    nonisolated static func loadInstallations(for host: SkillHost,
                                                      marketplaces: Set<String>) async
        -> InstallationLoad {
        guard !marketplaces.isEmpty, ProcessManager.resolve(host.command) != nil else {
            return InstallationLoad(installations: [:], failure: nil)
        }
        let result = await run(host.command, host.listArguments)
        guard result.ok else {
            return InstallationLoad(installations: [:], failure: result.failureMessage)
        }
        guard jsonObject(from: result.output) != nil else {
            return InstallationLoad(installations: [:], failure: "The agent returned an unreadable installation list.")
        }
        return InstallationLoad(installations: installedPlugins(from: result.output,
                                                                for: host,
                                                                marketplaces: marketplaces),
                                failure: nil)
    }

    // MARK: - Commands

    // A sign-in problem in plain words when that is what stopped git, git's own text
    // otherwise. A refresh uses this, for a marketplace already added; a first clone asks
    // GitSignIn directly because it also keeps the SSH address to offer.
    private nonisolated static func gitFailureMessage(_ result: CommandResult,
                                                      source: String) -> String {
        GitSignIn.problem(in: result.failureMessage, address: source, isSaved: true)?.message
            ?? result.failureMessage
    }

    struct CommandResult: Sendable {
        var output = ""
        var errorText = ""
        var status: Int32 = -1

        var ok: Bool { status == 0 }

        var failureMessage: String {
            let text = errorText.isBlank ? output.trimmed : errorText.trimmed
            return text.isEmpty ? "Command failed with exit code \(status)."
                : String(text.prefix(4_000))
        }
    }

    private nonisolated static func jsonObject(from output: String) -> Any? {
        let starts = [output.firstIndex(of: "{"), output.firstIndex(of: "[")].compactMap { $0 }
        guard let start = starts.min() else { return nil }
        let closing: Character = output[start] == "{" ? "}" : "]"
        guard let end = output.lastIndex(of: closing), start <= end,
              let data = String(output[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated static func run(_ command: String, _ arguments: [String]) async
        -> CommandResult {
        guard let path = ProcessManager.resolve(command) else {
            return CommandResult(errorText: "\(command) was not found on PATH.")
        }
        var environment: [String: String]
        if command == "git" {
            environment = GitEnvironment.nonInteractive(searchPath: ProcessManager.searchPath)
        } else {
            // Agent CLIs keep the user's locale: pinning it would change what they print.
            // There is still no terminal behind them, so any git they start must not try
            // to open one for a username.
            environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ProcessManager.searchPath
            environment["GIT_TERMINAL_PROMPT"] = "0"
        }

        do {
            let output = try await CommandRunner.run(
                executable: path,
                arguments: arguments,
                environment: environment,
                timeout: .seconds(180)
            )
            return CommandResult(output: output.output,
                                 errorText: output.errorOutput,
                                 status: output.status)
        } catch {
            return CommandResult(errorText: error.localizedDescription)
        }
    }
}
