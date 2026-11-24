import Foundation

// One file that carries a person's setup to another Mac. It holds what they built up over
// time - preferences, bots, the configuration, shortcuts, requests and the project list -
// and leaves out what only makes sense on this Mac: sessions, transcripts, worktrees and
// anything kept in the Keychain.
struct AppBackup: Codable, Equatable, Sendable {
    enum Part: String, Codable, CaseIterable, Identifiable, Sendable {
        case preferences, bots, configuration, shortcuts, requests, projects

        var id: String { rawValue }

        var title: String {
            switch self {
            case .preferences: "Preferences"
            case .bots: "Bots"
            case .configuration: "Configuration"
            case .shortcuts: "Shortcuts"
            case .requests: "Requests and environments"
            case .projects: "Projects and workspaces"
            }
        }

        // Projects are the one part added beside what is there. A new Mac may already
        // have sessions, and those belong to the projects it knows about.
        var replaces: Bool { self != .projects }

        fileprivate func owns(_ fileName: String) -> Bool {
            switch self {
            case .preferences: false
            case .bots: fileName.hasPrefix(AppBackup.botPrefix)
            case .configuration: fileName == SiteDefaults.fileName
            case .shortcuts: fileName == "shortcuts.json"
            case .requests: fileName == "dispatch.json" || fileName == "dispatch-auth.json"
            case .projects: fileName == AppBackup.projectsFile
            }
        }
    }

    static let formatName = "code-station-backup"
    static let currentVersion = 1
    static let pendingFileName = "pending-backup.json"
    fileprivate static let botPrefix = "agent-avatar"
    fileprivate static let projectsFile = "projects.json"

    var format = formatName
    var version = currentVersion
    var createdAt: Date
    // A property list, since that is the only shape every preference value fits.
    var preferences: Data?
    // Each file under the name it has in the data folder, byte for byte.
    var files: [String: Data]

    var parts: [Part] {
        Part.allCases.filter { part in
            part == .preferences ? preferences != nil : files.keys.contains(where: part.owns)
        }
    }

    // MARK: - Export

    static func make(configuration: Data,
                     support: URL = AppPaths.support,
                     projectsURL: URL = ProjectStore.defaultStoreURL,
                     defaults: UserDefaults = .standard,
                     domain: String = AppPaths.bundleID,
                     now: Date = .now) throws -> AppBackup {
        var files = [SiteDefaults.fileName: configuration]
        for name in ["shortcuts.json", "dispatch.json", "dispatch-auth.json"] {
            if let data = try PersistentFile.readIfPresent(support.appendingPathComponent(name)) {
                files[name] = data
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        for name in names where name.hasPrefix(botPrefix) {
            files[name] = try Data(contentsOf: support.appendingPathComponent(name))
        }
        if let data = try PersistentFile.readIfPresent(projectsURL) {
            files[projectsFile] = try portableProjects(data)
        }

        let portable = (defaults.persistentDomain(forName: domain) ?? [:])
            .filter { isPortable($0.key) }
        let preferences = try PropertyListSerialization.data(fromPropertyList: portable,
                                                             format: .binary, options: 0)
        return AppBackup(createdAt: now,
                         preferences: preferences,
                         files: files)
    }

    func encoded() throws -> Data {
        var data = try PersistentFile.makeEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    // Only folders the person chose travel. Tasks live in the app's own data folder and
    // their sessions do not move, so they are left behind with them.
    private static func portableProjects(_ data: Data) throws -> Data {
        var index = try PersistentFile.makeDecoder().decode(ProjectPersistence.Index.self, from: data)
        index.projects = index.projects.filter { $0.kind == .project }
        let kept = Set(index.projects.map(\.id))
        index.workspaces = index.workspaces?.compactMap { workspace in
            var workspace = workspace
            workspace.projectIDs = workspace.projectIDs.filter(kept.contains)
            workspace.worktreeProjectIDs = workspace.worktreeProjectIDs.filter(kept.contains)
            guard kept.contains(workspace.leadProjectID) else { return nil }
            return workspace
        }
        index.sessions = []
        index.selectedSessionID = nil
        index.selectedProjectID = nil
        return try PersistentFile.makeEncoder().encode(index)
    }

    // Preferences that point at this Mac's sessions, cache what a server said, or belong
    // to AppKit stay behind. Everything else is a choice the person made.
    static let machineKeys: Set<String> = [
        "selectedSessionID", "selectedProjectID", "selectedWorkspaceID",
        Preferences.hasCompletedOnboarding.key, "siteDefaultsPath", "appUpdateLastCheck",
        "cachedAppUpdateRelease", Preferences.dismissedAppUpdateVersion.key,
        "dayRibbonEntranceDay"
    ]
    private static let machinePrefixes = ["NS", "Apple", "com.apple.", "adoptedDefaultsFrom-",
                                          "skillsLastRefresh"]

    // Retired settings can remain in older preferences and backups.
    private static let retiredKeys: Set<String> = ["workingSetVisibility", "opensWorkingSetByDefault"]

    static func isPortable(_ key: String) -> Bool {
        !machineKeys.contains(key) && !retiredKeys.contains(key)
            && !machinePrefixes.contains(where: key.hasPrefix)
    }

    // MARK: - Import

    // A backup names its format at the top, and a team configuration never does, so one
    // file chooser can take either.
    static func isBackup(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["format"] as? String == formatName
    }

    static func read(_ url: URL) throws -> AppBackup {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError("The backup could not be read: \(error.localizedDescription)")
        }
        let backup: AppBackup
        do {
            backup = try PersistentFile.makeDecoder().decode(AppBackup.self, from: data)
        } catch {
            throw ImportError("This is not a Code Station backup.")
        }
        guard backup.format == formatName else {
            throw ImportError("This is not a Code Station backup.")
        }
        guard backup.version <= currentVersion else {
            throw ImportError("This backup was made by a newer version of Code Station. Update the app, then try again.")
        }
        return backup
    }

    func keeping(_ chosen: Set<Part>) -> AppBackup {
        var backup = self
        if !chosen.contains(.preferences) { backup.preferences = nil }
        backup.files = files.filter { name, _ in chosen.contains { $0.owns(name) } }
        return backup
    }

    // The running stores would write their own copies back over these files as the app
    // quits, so an import is set aside here and only applied on the next launch, before
    // any store has read anything.
    static func stage(_ backup: AppBackup, support: URL = AppPaths.support) throws {
        try PersistentFile.write(try backup.encoded(),
                                 to: support.appendingPathComponent(pendingFileName))
    }

    static func pending(support: URL = AppPaths.support) -> AppBackup? {
        let url = support.appendingPathComponent(pendingFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? read(url)
    }

    static func cancelPending(support: URL = AppPaths.support) {
        try? PersistentFile.removeIfPresent(support.appendingPathComponent(pendingFileName))
    }

    static func applyPending(support: URL = AppPaths.support,
                             projectsURL: URL = ProjectStore.defaultStoreURL,
                             defaults: UserDefaults = .standard) {
        let url = support.appendingPathComponent(pendingFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Gone first, so a backup that cannot be applied is not tried on every launch.
        defer { try? PersistentFile.removeIfPresent(url) }
        do {
            try read(url).apply(support: support, projectsURL: projectsURL, defaults: defaults)
            SessionLog.note("imported a backup")
        } catch {
            SessionLog.note("backup import failed: \(error.localizedDescription)")
        }
    }

    func apply(support: URL, projectsURL: URL, defaults: UserDefaults) throws {
        let projectIDs = try files[Self.projectsFile].map {
            try Self.mergeProjects($0, into: projectsURL)
        } ?? [:]

        if let preferences,
           let values = try PropertyListSerialization.propertyList(from: preferences, format: nil)
            as? [String: Any] {
            for (key, value) in values where Self.isPortable(key) {
                defaults.set(value, forKey: key)
            }
        }

        if files.keys.contains(where: Part.bots.owns) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
            for name in names where Part.bots.owns(name) {
                try PersistentFile.removeIfPresent(support.appendingPathComponent(name))
            }
        }
        for (name, data) in files where name != Self.projectsFile {
            // A name is only ever a file in the data folder, never a path out of it.
            guard name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix(".") else {
                continue
            }
            let restored = name == "shortcuts.json"
                ? try ShortcutStore.remappingProjects(in: data, using: projectIDs) : data
            try PersistentFile.write(restored, to: support.appendingPathComponent(name))
        }
        if files[SiteDefaults.fileName] != nil {
            Preferences.setSiteDefaultsURL(nil, in: defaults)
        }
    }

    // A folder already on the list keeps its own entry, and a workspace from the backup
    // is pointed at that entry instead.
    @discardableResult
    static func mergeProjects(_ data: Data, into url: URL) throws -> [UUID: UUID] {
        let decoder = PersistentFile.makeDecoder()
        let incoming = try decoder.decode(ProjectPersistence.Index.self, from: data)
        var index = try PersistentFile.readIfPresent(url).map {
            try decoder.decode(ProjectPersistence.Index.self, from: $0)
        } ?? ProjectPersistence.Index(projects: [], sessions: [], workspaces: [])

        func standardized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
        var idForPath = Dictionary(index.projects.map { (standardized($0.path), $0.id) },
                                   uniquingKeysWith: { first, _ in first })
        var knownIDs = Set(index.projects.map(\.id))
        var idMap: [UUID: UUID] = [:]
        for incomingProject in incoming.projects {
            let path = standardized(incomingProject.path)
            if let existing = idForPath[path] {
                idMap[incomingProject.id] = existing
                continue
            }
            var project = incomingProject
            if knownIDs.contains(project.id) { project.id = UUID() }
            idMap[incomingProject.id] = project.id
            idForPath[path] = project.id
            knownIDs.insert(project.id)
            index.projects.append(project)
        }

        var workspaces = index.workspaces ?? []
        var knownWorkspaces = Set(workspaces.map(\.id))
        for workspace in incoming.workspaces ?? [] where !knownWorkspaces.contains(workspace.id) {
            guard let lead = idMap[workspace.leadProjectID] else { continue }
            var workspace = workspace
            workspace.leadProjectID = lead
            workspace.projectIDs = workspace.projectIDs.compactMap { idMap[$0] }
            workspace.worktreeProjectIDs = workspace.worktreeProjectIDs.compactMap { idMap[$0] }
            workspaces.append(workspace)
            knownWorkspaces.insert(workspace.id)
        }
        index.workspaces = workspaces
        try PersistentFile.write(try PersistentFile.makeEncoder().encode(index), to: url)
        return idMap
    }

    // MARK: - Summary

    func detail(for part: Part) -> String {
        switch part {
        case .preferences:
            let values = preferences.flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            }
            return counted(values?.count ?? 0, "setting")
        case .bots:
            return counted(files.keys.count { Part.bots.owns($0) && $0.hasSuffix(".png") },
                           "picture")
        case .configuration:
            return files[SiteDefaults.fileName]
                .flatMap { try? SiteDefaults.decode($0, from: URL(fileURLWithPath: SiteDefaults.fileName)) }
                .map(\.summary) ?? "Shared configuration"
        case .shortcuts:
            return counted(count("shortcuts", in: "shortcuts.json"), "shortcut")
        case .requests:
            let requests = counted(count("requests", in: "dispatch.json"), "request")
            return "\(requests). Secrets stay on the old Mac."
        case .projects:
            let projects = counted(count("projects", in: Self.projectsFile), "project")
            let workspaces = count("workspaces", in: Self.projectsFile)
            return workspaces == 0 ? projects : "\(projects), \(counted(workspaces, "workspace"))"
        }
    }

    private func count(_ key: String, in file: String) -> Int {
        guard let data = files[file],
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object[key] as? [Any] else { return 0 }
        return list.count
    }
}
