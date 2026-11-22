import Foundation

extension GitInspector {
    static func reviewChanges(in snapshot: GitSnapshot) async -> [String: ViewedChange] {
        guard snapshot.state == .ready, let tool = Git.tool() else { return [:] }
        return await Git.offMain(lane: .interactive) {
            let url = URL(fileURLWithPath: snapshot.root)
            let head = Git.run(tool, ["rev-parse", "--verify", "HEAD"], in: url)
            let last = head.ok ? head.trimmedText : Git.emptyTree
            let groups = Dictionary(grouping: snapshot.files) { snapshot.diffBase(for: $0) ?? last }
            var result: [String: ViewedChange] = [:]
            for (base, files) in groups {
                result.merge(reviewChanges(files, base: base, tool: tool, root: url)) { _, fresh in fresh }
            }
            return result
        }
    }

    private static func reviewChanges(_ files: [GitChange], base: String,
                                      tool: Git.Tool, root: URL) -> [String: ViewedChange] {
        guard !files.isEmpty else { return [:] }
        let paths = files.map { $0.originalPath ?? $0.path }
        let tree = Git.run(tool, ["--literal-pathspecs", "ls-tree", "-rz", base, "--"] + paths, in: root)
        guard tree.ok, !tree.truncated else { return [:] }
        var before: [String: ViewedChange.Version] = [:]
        for entry in tree.text.split(separator: "\0") {
            let fields = entry.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let object = fields[0].split(separator: " ")
            guard object.count == 3 else { continue }
            before[String(fields[1])] = .init(mode: String(object[0]), blob: String(object[2]))
        }
        var result: [String: ViewedChange] = [:]
        for file in files where file.kind != .conflicted {
            guard let after = FileVersion.entry(at: root.appendingPathComponent(file.path)) else { continue }
            result[file.path] = ViewedChange(before: before[file.originalPath ?? file.path] ?? .absent,
                                              after: after, originalPath: file.originalPath)
        }
        return result
    }

    static func reviewDiff(for change: GitChange, root: String, base: String? = nil) async -> FileDiff {
        guard let tool = Git.tool() else { return FileDiff(note: Git.unavailableMessage) }
        let context = await Git.offMain(lane: .interactive) {
            let url = URL(fileURLWithPath: root)
            let head = Git.run(tool, ["rev-parse", "--verify", "HEAD"], in: url)
            let base = base ?? (head.ok ? head.trimmedText : Git.emptyTree)
            return (base, reviewChanges([change], base: base, tool: tool, root: url)[change.path])
        }
        var diff = await readReviewDiff(for: change, root: root, base: context.0)
        let after = await Git.offMain(lane: .interactive) {
            reviewChanges([change], base: context.0, tool: tool,
                          root: URL(fileURLWithPath: root))[change.path]
        }
        // A file edited while its diff was read has no single version the user saw.
        if context.1 == after { diff.reviewChange = after }
        return diff
    }
}
