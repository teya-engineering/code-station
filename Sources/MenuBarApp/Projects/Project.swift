import Foundation

// A project is just a folder on disk. A session runs Claude Code either directly in
// this directory or in a worktree of its own - see ChatSession.worktreePath.
struct Project: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case project
        case adHoc
    }

    var id: UUID
    var name: String
    var path: String
    var kind: Kind
    var isPinned: Bool
    // Nil keeps the stable icon derived from the project's identity. Once changed, the
    // chosen bundled artwork follows the project everywhere it appears.
    var sidebarAvatarIndex: Int?
    // The saved prompt behind a task. Nil on normal projects, and on tasks created
    // before prompts existed, which read as an empty prompt.
    var task: TaskSpec?

    var url: URL { URL(fileURLWithPath: path) }

    // Shown in the sidebar under the project name.
    var collapsedPath: String { path.abbreviatedPath }

    // Only a git checkout can back a worktree session. `.git` is a directory in a normal
    // clone and a file in a worktree or submodule, so test for either.
    var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }

    init(id: UUID = UUID(), name: String, path: String, kind: Kind = .project,
         isPinned: Bool = false, sidebarAvatarIndex: Int? = nil, task: TaskSpec? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.isPinned = isPinned
        self.sidebarAvatarIndex = sidebarAvatarIndex
        self.task = task
    }

    // Folder name is a good enough default title.
    init(url: URL) {
        self.init(name: url.lastPathComponent, path: url.path)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, isPinned, sidebarAvatarIndex, task
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? Self.legacyKind(for: path)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sidebarAvatarIndex = try container.decodeIfPresent(Int.self,
                                                            forKey: .sidebarAvatarIndex)
        task = try container.decodeIfPresent(TaskSpec.self, forKey: .task)
    }

    // Ad-hoc tasks created before the kind was stored can be identified by the private
    // directory the app has always used for them. User-selected folders keep their normal
    // project kind even when older index files do not contain this field.
    private static func legacyKind(for path: String) -> Kind {
        let parent = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        let taskRoot = AppPaths.support
            .appendingPathComponent("ad-hoc-tasks", isDirectory: true)
            .standardizedFileURL
        return parent == taskRoot ? .adHoc : .project
    }
}

extension String {
    func pathRelative(to directory: String) -> String? {
        let path = URL(fileURLWithPath: self).standardizedFileURL.path
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard path != directory else { return "" }

        let prefix = directory == "/" ? "/" : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let relativePath = pathRelative(to: home) else { return self }
        return relativePath.isEmpty ? "~" : "~/\(relativePath)"
    }
}
