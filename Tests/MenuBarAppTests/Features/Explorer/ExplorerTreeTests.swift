import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerTreeTests {
    private let scratch = ScratchDirectory(prefix: "explorer-tree")
    private var root: URL { scratch.url.resolvingSymlinksInPath() }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "text".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aChainOfSingleFoldersIsReadInOneGoAndOpensAsOne() async throws {
        let leaf = try file("one/two/three/file.txt")
        _ = try file("beside.txt")
        let tree = ExplorerTree()
        tree.expanded = [root.appendingPathComponent("one").path]
        await tree.load(root.path)

        let deepest = leaf.deletingLastPathComponent().path
        #expect(tree.children[deepest]?.map(\.name) == ["file.txt"])
        // The chain is one row, so open on any link of it means open on the last.
        #expect(tree.expanded.contains(deepest))
        let rows = ExplorerTreeRow.rows(in: root.path, children: tree.children, expanded: tree.expanded)
        #expect(rows.map(\.name) == ["one / two / three", "file.txt", "beside.txt"])
        #expect(tree.loadingFolders.isEmpty)
    }

    @Test func revealingAFileOpensEveryFolderAboveIt() async throws {
        let leaf = try file("Sources/App/Views/file.swift")
        _ = try file("Sources/App/other.swift")
        _ = try file("Sources/beside.swift")
        let tree = ExplorerTree()
        await tree.load(root.path)
        #expect(tree.expanded.isEmpty)

        await tree.openFolders(leadingTo: leaf, beneath: root)
        #expect(tree.expanded == Set(["Sources", "Sources/App", "Sources/App/Views"].map {
            root.appendingPathComponent($0).path
        }))
        #expect(tree.children[leaf.deletingLastPathComponent().path]?.map(\.path) == [leaf.path])
    }

    @Test func openFoldersFollowAFolderToItsNewName() async throws {
        let old = try folder("Sources")
        _ = try file("Sources/App/file.swift")
        _ = try file("Sources/beside.swift")
        _ = try file("SourcesExtra/other.swift")
        let extra = root.appendingPathComponent("SourcesExtra").path
        let tree = ExplorerTree()
        tree.expanded = [old.path, old.appendingPathComponent("App").path, extra]
        await tree.load(root.path)
        for path in tree.expanded.sorted() { await tree.load(path) }
        let revision = tree.statusRevision

        let new = root.appendingPathComponent("Code")
        try FileManager.default.moveItem(at: old, to: new)
        await tree.moved(from: old.path, to: new)

        #expect(tree.expanded == [new.path, new.appendingPathComponent("App").path, extra])
        #expect(tree.children[old.path] == nil)
        #expect(tree.children[old.appendingPathComponent("App").path] == nil)
        #expect(tree.children[new.appendingPathComponent("App").path]?.map(\.name) == ["file.swift"])
        #expect(tree.children[root.path]?.map(\.name) == ["Code", "SourcesExtra"])
        #expect(tree.children[extra]?.map(\.name) == ["other.swift"])
        #expect(tree.statusRevision == revision + 1)
    }

    @Test func aRemovedFolderTakesItsOpenFoldersWithIt() async throws {
        let gone = try folder("Sources")
        _ = try file("Sources/App/file.swift")
        _ = try file("Sources/beside.swift")
        _ = try file("SourcesExtra/other.swift")
        let extra = root.appendingPathComponent("SourcesExtra").path
        let tree = ExplorerTree()
        tree.expanded = [gone.path, gone.appendingPathComponent("App").path, extra]
        await tree.load(root.path)
        for path in tree.expanded.sorted() { await tree.load(path) }
        let node = try #require(tree.children[root.path]?.first { $0.name == "Sources" })

        try FileManager.default.removeItem(at: gone)
        await tree.removed(node)

        #expect(tree.expanded == [extra])
        #expect(tree.children.keys.sorted() == [root.path, extra].sorted())
        #expect(tree.children[root.path]?.map(\.name) == ["SourcesExtra"])
    }

    @Test func hiddenFilesAreListedOnlyWhenAskedFor() async throws {
        _ = try file(".hidden")
        _ = try file("shown.txt")
        let tree = ExplorerTree()
        tree.showHidden = false
        await tree.load(root.path)
        #expect(tree.children[root.path]?.map(\.name) == ["shown.txt"])

        tree.showHidden = true
        await tree.reopenFolders(roots: [root.path])
        #expect(tree.children[root.path]?.map(\.name) == [".hidden", "shown.txt"])
    }

    @Test func aFolderThatCannotBeReadKeepsItsErrorUntilItReadsAgain() async throws {
        let missing = root.appendingPathComponent("later", isDirectory: true)
        let tree = ExplorerTree()
        await tree.load(missing.path)
        #expect(tree.folderErrors[missing.path] != nil)
        #expect(tree.children[missing.path] == nil)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await tree.load(missing.path)
        #expect(tree.folderErrors[missing.path] == nil)
        #expect(tree.children[missing.path] == [])
    }
}
