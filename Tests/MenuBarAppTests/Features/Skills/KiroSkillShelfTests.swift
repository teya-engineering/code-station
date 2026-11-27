import Foundation
import Testing
@testable import MenuBarApp

struct KiroSkillShelfTests {
    private let scratch = ScratchDirectory(prefix: "kiro-skills")

    private var shelf: KiroSkillShelf { KiroSkillShelf(directory: scratch.path("kiro/skills")) }

    // A marketplace checkout with one package holding two skills and an agent Kiro has
    // no place for.
    private func marketplace(version: String = "1.0.0", body: String = "Write docs.",
                             skills: [String] = ["readme-writer", "adr-writer"]) throws -> URL {
        let root = scratch.path("market-\(version)")
        let package = root.appendingPathComponent("plugins/docs")
        let files = FileManager.default
        for skill in skills {
            let folder = package.appendingPathComponent("skills/\(skill)")
            try files.createDirectory(at: folder.appendingPathComponent("references"), withIntermediateDirectories: true)
            try Data("---\nname: \(skill)\ndescription: \(skill)\n---\n\(body)\n".utf8)
                .write(to: folder.appendingPathComponent("SKILL.md"))
            try Data("notes".utf8).write(to: folder.appendingPathComponent("references/notes.md"))
        }
        try files.createDirectory(at: package.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("agent".utf8).write(to: package.appendingPathComponent("agents/helper.md"))
        try files.createDirectory(at: package.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try Data(#"{"name":"docs","version":"\#(version)"}"#.utf8)
            .write(to: package.appendingPathComponent(".claude-plugin/plugin.json"))
        return root
    }

    private func skillNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: shelf.directory.path)) ?? []).sorted()
    }

    @Test func installsThePackagesSkillsAndReadsThemBack() throws {
        let root = try marketplace()
        let folder = try KiroSkillShelf.packageFolder(source: "./plugins/docs", marketplaceRoot: root)
        try shelf.install(package: "docs", marketplace: "team", version: nil, from: folder)

        #expect(skillNames() == ["adr-writer", "readme-writer"])
        let copied = shelf.directory.appendingPathComponent("adr-writer")
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("references/notes.md").path))
        #expect(shelf.installations(marketplaces: ["team"]) == ["docs@team": .init(version: "1.0.0", enabled: true)])
        #expect(shelf.installations(marketplaces: ["other"]).isEmpty)
    }

    @Test func updateReplacesTheCopiesAndRemoveLeavesOtherSkills() throws {
        let files = FileManager.default
        let own = shelf.directory.appendingPathComponent("my-own")
        try files.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: own.appendingPathComponent("SKILL.md"))

        let first = try KiroSkillShelf.packageFolder(source: "./plugins/docs", marketplaceRoot: try marketplace())
        try shelf.install(package: "docs", marketplace: "team", version: "1.0.0", from: first)
        let second = try KiroSkillShelf.packageFolder(source: "plugins/docs",
                                                      marketplaceRoot: try marketplace(version: "2.0.0", body: "New."))
        try shelf.install(package: "docs", marketplace: "team", version: "2.0.0", from: second)

        #expect(shelf.installations(marketplaces: ["team"])["docs@team"]?.version == "2.0.0")
        let skill = try String(contentsOf: shelf.directory.appendingPathComponent("readme-writer/SKILL.md"), encoding: .utf8)
        #expect(skill.contains("New."))

        try shelf.remove(package: "docs", marketplace: "team")
        #expect(skillNames() == ["my-own"])
        #expect(shelf.installations(marketplaces: ["team"]).isEmpty)
    }

    // A dangling link is not seen as a skill by the name check, but still blocks the move,
    // which makes the update fail part way through.
    @Test func anUpdateThatFailsPartWayLeavesTheOldInstallInPlace() throws {
        let first = try KiroSkillShelf.packageFolder(source: "./plugins/docs", marketplaceRoot: try marketplace())
        try shelf.install(package: "docs", marketplace: "team", version: "1.0.0", from: first)
        try FileManager.default.createSymbolicLink(at: shelf.directory.appendingPathComponent("zeta"),
                                                   withDestinationURL: scratch.path("missing"))
        let second = try KiroSkillShelf.packageFolder(
            source: "./plugins/docs",
            marketplaceRoot: try marketplace(version: "2.0.0", body: "New.",
                                             skills: ["readme-writer", "adr-writer", "zeta"]))

        #expect(throws: (any Error).self) {
            try shelf.install(package: "docs", marketplace: "team", version: "2.0.0", from: second)
        }
        #expect(shelf.installations(marketplaces: ["team"])["docs@team"]?.version == "1.0.0")
        let skill = try String(contentsOf: shelf.directory.appendingPathComponent("readme-writer/SKILL.md"), encoding: .utf8)
        #expect(skill.contains("Write docs."))
        #expect(skillNames() == ["adr-writer", "readme-writer", "zeta"])
    }

    @Test func aPackageAtTheMarketplaceRootCanBeCopied() throws {
        let root = scratch.path("market")
        #expect(try KiroSkillShelf.packageFolder(source: "./", marketplaceRoot: root).path
            == root.standardizedFileURL.path)
    }

    @Test func aSkillOfTheSameNameFromElsewhereStopsTheInstall() throws {
        let theirs = shelf.directory.appendingPathComponent("adr-writer")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: theirs.appendingPathComponent("SKILL.md"))
        let folder = try KiroSkillShelf.packageFolder(source: "./plugins/docs", marketplaceRoot: try marketplace())

        #expect(throws: KiroSkillShelf.Failure.self) {
            try shelf.install(package: "docs", marketplace: "team", version: nil, from: folder)
        }
        #expect(skillNames() == ["adr-writer"])
        #expect(try String(contentsOf: theirs.appendingPathComponent("SKILL.md"), encoding: .utf8) == "theirs")
    }

    @Test func onlyPackagesInsideTheMarketplaceCanBeCopied() throws {
        let root = scratch.path("market")
        for source in [nil, "", "https://github.com/org/package", "/elsewhere", "../outside"] {
            #expect(throws: KiroSkillShelf.Failure.self) {
                _ = try KiroSkillShelf.packageFolder(source: source, marketplaceRoot: root)
            }
        }
        let empty = root.appendingPathComponent("plugins/empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: KiroSkillShelf.Failure.self) {
            try shelf.install(package: "empty", marketplace: "team", version: nil, from: empty)
        }
    }

    @Test func aPackageFetchedFromElsewhereDecodesWithoutASource() throws {
        let marketplace = try SkillsManager.decodeMarketplace(Data(#"""
        {"name":"team","plugins":[{"name":"far","description":"Far","source":{"source":"github","repo":"org/far"}}]}
        """#.utf8))
        #expect(marketplace.plugins.first?.source == nil)
    }

    @Test func aLocalMarketplaceResolvesPackagesFromItsRoot() {
        let local = SkillMarketplaceConfiguration(source: "/work/market/.claude-plugin/marketplace.json",
                                                  sourceKind: .localFile, marketplace: "team", label: "team")
        let cache = URL(fileURLWithPath: "/cache/abc")
        #expect(SkillsManager.marketplaceRoot(local, cache: cache).path == "/work/market")
        let cloned = SkillMarketplaceConfiguration(source: "git@host:org/market.git",
                                                   sourceKind: .gitRepository, marketplace: "team", label: "team")
        #expect(SkillsManager.marketplaceRoot(cloned, cache: cache) == cache)
    }
}
