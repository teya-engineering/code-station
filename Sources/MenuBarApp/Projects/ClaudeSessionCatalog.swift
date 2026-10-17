import Foundation

// A conversation Claude Code had outside the app, found in its own history folder. It is
// what a row in the import sheet says about one file, read without loading the file.
struct ClaudeSessionCandidate: Identifiable, Hashable, Sendable {
    // The file's name, which is the id `claude --resume` takes.
    let id: String
    let file: URL
    let cwd: String
    // The name the session was given with /rename, else the one Claude Code wrote for it.
    // Nil when it has neither, and the first prompt names it instead.
    let title: String?
    let firstPrompt: String?
    let startedAt: Date?
    let lastActivity: Date
    let gitBranch: String?
    let bytes: Int

    var displayTitle: String {
        if let title, !title.isBlank { return title }
        let words = (firstPrompt ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "Untitled session" }
        return words.count > 48 ? String(words.prefix(48)) + "…" : words
    }
}

// Reads `~/.claude/projects`, where Claude Code keeps one JSONL file per conversation in a
// folder named after the directory it ran in.
//
// Those files grow to hundreds of megabytes, so a listing reads only the start and the end
// of each one: the start says where the session ran and what it was asked first, the end
// says when it last moved and what it is called now. The whole file is only read when a
// session is actually imported.
enum ClaudeSessionCatalog {
    // A folder picked by hand in the import sheet. An app opened from the Finder does not
    // see the variables a shell sets, so CLAUDE_CONFIG_DIR alone cannot find a history
    // kept somewhere other than the default.
    static let chosenRootKey = "claudeSessionHistoryFolder"

    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard) -> URL {
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

    // How much of each end of a file is read for a listing. Big enough to get past the
    // instructions and attachments a session opens with, small enough that a folder of
    // long sessions lists in a blink.
    static let windowBytes = 256 * 1024

    // The sessions that ran in exactly this folder, newest first. A session started in a
    // subfolder is left out: resuming looks the conversation up from the directory it runs
    // in, and the app runs a project's sessions from the project folder.
    //
    // `known` holds the conversation ids the app already has. Every turn the app runs
    // forks a fresh id, and each fork leaves a file of its own behind, so without this a
    // folder already used in the app would list a copy for every turn it ever took.
    static func sessions(in folder: String, excluding known: Set<String> = [],
                         root: URL = defaultRoot()) -> [ClaudeSessionCandidate] {
        let target = standardized(folder)
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var found: [ClaudeSessionCandidate] = []
        for directory in directories {
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !known.contains(id),
                      let candidate = candidate(at: file),
                      standardized(candidate.cwd) == target else { continue }
                found.append(candidate)
            }
        }
        return found.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func candidate(at file: URL) -> ClaudeSessionCandidate? {
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

        return ClaudeSessionCandidate(
            id: file.deletingPathExtension().lastPathComponent,
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
        var cwd: String?
        var entrypoint: String?
        var gitBranch: String?
        var firstPrompt: String?
        var title: String?
        var customTitle: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var answered = false

        mutating func take(_ object: [String: Any]) {
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
    static func historyFolder(from picked: URL) -> URL {
        let inner = picked.appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        if picked.lastPathComponent != "projects",
           FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return inner
        }
        return picked
    }

    static func standardized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
