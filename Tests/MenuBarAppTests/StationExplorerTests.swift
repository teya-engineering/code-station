import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the Explorer tab, as the
// GUI's `ExplorerView` offers it. The session's checkout read a folder at a time, file
// name search, find in files, and creating, renaming and trashing files. Paths are
// relative to the session's working directory.
@MainActor
struct StationExplorerTests {

    @MainActor
    private final class Checkout {
        let scratch = ScratchDirectory(prefix: "station-explorer")
        let root: URL
        let commands: any StationInterface
        let sessionID: String
        // Stands in for the Trash, which tests leave alone.
        let trash = TestTrash()

        init(_ kind: StationImplementation, files: [String: String], worktree: Bool = false) throws {
            let project = scratch.path("alpha")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let tree = scratch.path("tree")
            root = worktree ? tree : project
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let store = ProjectStore(storeURL: scratch.path("projects.json"))
            let added = try #require(store.addProject(at: project))
            let session = worktree
                ? try store.insertSession(in: added.id, worktreePath: tree.path, worktreeBranch: "code-station/x").get()
                : try store.insertSession(in: added.id).get()
            sessionID = session.id.uuidString
            let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
            station.trash = trash.move
            commands = kind.connect(to: station)
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
    }

    // The root lists folders first, then files by name as Finder sorts them, with `.git`
    // left out and other hidden files kept. A folder is read when it is asked for.
    @Test(arguments: StationImplementation.allCases)
    func theTreeIsReadAFolderAtATime(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: [
            "README.md": "hello\n", "file10.txt": "", "file9.txt": "",
            "Sources/app.swift": "print(1)\n", "Sources/Deep/more.swift": "",
            ".env": "X=1\n", ".git/HEAD": "ref\n",
        ])

        let root = try await checkout.commands.readFolder(checkout.sessionID, path: "")

        #expect(root.root == checkout.root.path)
        #expect(root.path == "")
        #expect(root.entries.map(\.name) == ["Sources", ".env", "file9.txt", "file10.txt", "README.md"])
        #expect(root.entries.map(\.isDirectory) == [true, false, false, false, false])
        #expect(root.entries.first { $0.name == "README.md" }?.size == 6)

        let sources = try await checkout.commands.readFolder(checkout.sessionID, path: "Sources")

        #expect(sources.path == "Sources")
        #expect(sources.entries.map(\.path) == ["Sources/Deep", "Sources/app.swift"])
    }

    // A worktree session explores its own worktree, not the project folder beside it.
    @Test(arguments: StationImplementation.allCases)
    func aWorktreeSessionExploresItsWorktree(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: ["only-here.txt": "x\n"], worktree: true)

        let root = try await checkout.commands.readFolder(checkout.sessionID, path: "")

        #expect(root.root == checkout.root.path)
        #expect(root.entries.map(\.name) == ["only-here.txt"])
    }

    // A path that leaves the checkout, a folder that is not there and an unknown session
    // are refused.
    @Test(arguments: StationImplementation.allCases)
    func pathsOutsideTheCheckoutAreRefused(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: ["a.txt": ""])

        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.readFolder(checkout.sessionID, path: "../")
        }
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.readFolder(checkout.sessionID, path: "/etc")
        }
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.readFolder(checkout.sessionID, path: "missing")
        }
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.trashFile(checkout.sessionID, path: "../alpha")
        }
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.readFolder(UUID().uuidString, path: "")
        }
    }

    // File name search ranks the exact name first, then names that start with the query,
    // then names and paths that hold it, case ignored.
    @Test(arguments: StationImplementation.allCases)
    func fileNameSearchRanksTheBestMatchFirst(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: [
            "docs/app.md": "", "Sources/App.swift": "", "Sources/MyApp.swift": "",
            "app/notes.txt": "", "other.txt": "",
        ])

        let found = try await checkout.commands.searchFileNames(checkout.sessionID, query: "app")

        #expect(found.map(\.path) == ["docs/app.md", "Sources/App.swift", "Sources/MyApp.swift", "app/notes.txt"])
        #expect(try await checkout.commands.searchFileNames(checkout.sessionID, query: "  ").isEmpty)
    }

    // Find in files lists each file's lines holding the query, case ignored, with where
    // each hit falls on the line.
    @Test(arguments: StationImplementation.allCases)
    func findInFilesListsTheLinesHoldingTheQuery(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: [
            "a.swift": "let one = 1\n    let Token = 2\n",
            "b/c.txt": "nothing\nthe token, the TOKEN\n",
            "d.txt": "no match\n",
        ])

        let found = try await checkout.commands.findInFiles(checkout.sessionID, query: "token")

        #expect(found.files.map(\.path) == ["a.swift", "b/c.txt"])
        #expect(found.files[0].lines.map(\.number) == [2])
        #expect(found.files[0].lines[0].text == "let Token = 2")
        #expect(found.files[0].lines[0].hits == [.init(location: 4, length: 5)])
        #expect(found.files[1].lines.map(\.number) == [2])
        #expect(found.files[1].lines[0].hits.count == 2)
        #expect(found.lineCount == 2)
        #expect(found.more == false)
    }

    // A file or folder is made with the name typed; a name already taken is refused.
    @Test(arguments: StationImplementation.allCases)
    func createsAFileOrFolderWithTheNameGiven(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: ["Sources/app.swift": ""])

        let file = try await checkout.commands.createFile(checkout.sessionID, in: "Sources", name: "new.swift",
                                                          isFolder: false)
        let folder = try await checkout.commands.createFile(checkout.sessionID, in: "", name: "Docs",
                                                            isFolder: true)

        #expect(file.path == "Sources/new.swift")
        #expect(file.isDirectory == false)
        #expect(folder.path == "Docs")
        #expect(folder.isDirectory)
        #expect(checkout.exists("Sources/new.swift"))
        #expect(checkout.exists("Docs"))
        await #expect(throws: StationRefusal("Something called app.swift is already in this folder.")) {
            try await checkout.commands.createFile(checkout.sessionID, in: "Sources", name: "app.swift",
                                                   isFolder: false)
        }
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.createFile(checkout.sessionID, in: "", name: "a/b", isFolder: false)
        }
    }

    // A rename keeps the item in its folder under its new name, and refuses a name in use.
    @Test(arguments: StationImplementation.allCases)
    func renamesAFileInItsFolder(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: ["Sources/old.swift": "x\n", "Sources/taken.swift": ""])

        let renamed = try await checkout.commands.renameFile(checkout.sessionID, path: "Sources/old.swift",
                                                             to: "new.swift")

        #expect(renamed.path == "Sources/new.swift")
        #expect(renamed.size == 2)
        #expect(!checkout.exists("Sources/old.swift"))
        #expect(checkout.exists("Sources/new.swift"))
        await #expect(throws: StationRefusal("Something called taken.swift is already in this folder.")) {
            try await checkout.commands.renameFile(checkout.sessionID, path: "Sources/new.swift", to: "taken.swift")
        }
    }

    // Trashing takes the item out of the checkout; one that is already gone is refused.
    @Test(arguments: StationImplementation.allCases)
    func trashesAFile(_ kind: StationImplementation) async throws {
        let checkout = try Checkout(kind, files: ["gone.txt": "bye\n", "kept.txt": ""])

        try await checkout.commands.trashFile(checkout.sessionID, path: "gone.txt")

        #expect(!checkout.exists("gone.txt"))
        #expect(checkout.trash.moved == ["gone.txt"])
        #expect(checkout.exists("kept.txt"))
        await #expect(throws: StationRefusal.self) {
            try await checkout.commands.trashFile(checkout.sessionID, path: "gone.txt")
        }
    }
}
