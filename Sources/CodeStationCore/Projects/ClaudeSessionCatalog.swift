import Foundation

// Reads `~/.claude/projects`, where Claude Code keeps one JSONL file per conversation in a
// folder named after the directory it ran in.
//
// Those files grow to hundreds of megabytes, so a listing reads only the start and the end
// of each one: the start says where the session ran and what it was asked first, the end
// says when it last moved and what it is called now. The whole file is only read when a
// session is actually imported.
public enum ClaudeSessionCatalog {
    // A folder picked by hand in the import sheet. An app opened from the Finder does not
    // see the variables a shell sets, so CLAUDE_CONFIG_DIR alone cannot find a history
    // kept somewhere other than the default.
    public static let chosenRootKey = "claudeSessionHistoryFolder"

    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = Preferences.defaults) -> URL {
        if let configured = environment["CODE_STATION_CLAUDE_PROJECTS"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let chosen = defaults.string(forKey: chosenRootKey), !chosen.isEmpty {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // Bound metadata reads even when conversations contain large attachments or tool output.
    public static let windowBytes = 256 * 1024

    // Only histories for this project folder belong in its import list.
    //
    // `known` holds the conversation ids the app already has. Every turn the app runs
    // forks a fresh id, and each fork leaves a file of its own behind, so without this a
    // folder already used in the app would list a copy for every turn it ever took.
    public static func sessions(in folder: String, excluding known: Set<String> = [],
                         root: URL = defaultRoot(),
                         read: (URL) -> ExternalSessionCandidate? = candidate(at:)) -> [ExternalSessionCandidate] {
        let target = standardized(folder)
        let manager = FileManager.default
        let encoded = target.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-",
                                                   options: .regularExpression)
        let directories: [URL]
        if encoded.count <= 200 {
            directories = [root.appendingPathComponent(encoded, isDirectory: true)]
        } else {
            directories = ((try? manager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(String(encoded.prefix(200)) + "-") }
        }
        var found: [ExternalSessionCandidate] = []
        for directory in directories {
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !known.contains(ImportedSessionOrigin.key(agent: .claudeCode, sessionID: id)),
                      let candidate = read(file),
                      standardized(candidate.cwd) == target else { continue }
                found.append(candidate)
            }
        }
        return found.sorted { $0.lastActivity > $1.lastActivity }
    }

    public static func candidate(at file: URL) -> ExternalSessionCandidate? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard size > 0 else { return nil }

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: windowBytes)) ?? Data()
        var tail = Data()
        if size > windowBytes {
            try? handle.seek(toOffset: UInt64(max(windowBytes, size - windowBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }

        var reading = Reading()
        // A window can start or stop in the middle of a line. Those halves are not JSON
        // and fail to parse, which drops them without any special care.
        for object in records(in: head) { reading.take(object) }
        for object in records(in: tail) { reading.take(object) }

        guard let cwd = reading.cwd,
              // Runs started with -p (scripts, other apps, this app itself) are not
              // conversations anyone sat through, so they are not offered.
              !(reading.entrypoint?.hasPrefix("sdk") ?? false),
              reading.firstPrompt != nil || reading.title != nil,
              // A session Claude never answered was opened and left, most often to type
              // /resume and jump into another one. There is nothing in it to carry on.
              reading.answered,
              let last = reading.lastTimestamp ?? modificationDate(of: file)
        else { return nil }

        return ExternalSessionCandidate(
            sessionID: file.deletingPathExtension().lastPathComponent,
            file: file,
            cwd: cwd,
            title: reading.customTitle ?? reading.title,
            firstPrompt: reading.firstPrompt,
            startedAt: reading.firstTimestamp,
            lastActivity: last,
            gitBranch: reading.gitBranch,
            bytes: size)
    }

    // MARK: - Private

    private struct Reading {
        public var cwd: String?
        public var entrypoint: String?
        public var gitBranch: String?
        public var firstPrompt: String?
        public var title: String?
        public var customTitle: String?
        public var firstTimestamp: Date?
        public var lastTimestamp: Date?
        public var answered = false

        public mutating func take(_ object: [String: Any]) {
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if entrypoint == nil, let value = object["entrypoint"] as? String { entrypoint = value }
            if let value = object["gitBranch"] as? String, !value.isEmpty { gitBranch = value }
            if let date = ClaudeTranscriptImport.date(object["timestamp"]) {
                if firstTimestamp == nil { firstTimestamp = date }
                if lastTimestamp.map({ date > $0 }) ?? true { lastTimestamp = date }
            }
            switch object["type"] as? String {
            case "custom-title":
                if let value = object["customTitle"] as? String, !value.isBlank { customTitle = value }
            case "ai-title":
                if let value = object["aiTitle"] as? String, !value.isBlank { title = value }
            case "user":
                if firstPrompt == nil, let prompt = ClaudeTranscriptImport.prompt(in: object) {
                    firstPrompt = prompt
                }
            case "assistant":
                if object["isSidechain"] as? Bool != true { answered = true }
            default:
                break
            }
        }
    }

    private static func records(in data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
    }

    private static func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // The folder someone picked, taken as either the history folder itself or the Claude
    // folder above it, since `.claude` is the one people know by name.
    public static func historyFolder(from picked: URL) -> URL {
        let inner = picked.appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        if picked.lastPathComponent != "projects",
           FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return inner
        }
        return picked
    }

    public static func standardized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
