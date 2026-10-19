import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // The Explorer tab over an open session, as the GUI's Explorer: the checkout as a
    // tree, file name search, find in files, a file handed to `$EDITOR`, and creating,
    // renaming and trashing files.
    @MainActor
    @Suite
    struct ExplorerTests {

        private func open(_ files: [String: String], editor: String = "myedit") async throws -> (TUIHarness, Project) {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            let alpha = try tui.addProject("alpha")
            for (path, text) in files {
                let url = alpha.url.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try tui.addSession("Fix the login bug", in: alpha)
            tui.environment = ["EDITOR": editor]
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("5", []))
            return (tui, alpha)
        }

        private func row(_ tui: TUIHarness, _ fragment: String) -> VirtualScreen.Line? {
            tui.mainPane.first { $0.text.contains(fragment) }
        }

        // The tree lists folders first, the top row picked; l opens a folder in place and
        // h folds it again.
        @Test func theTreeOpensAndFoldsFolders() async throws {
            let (tui, _) = try await open(["README.md": "hi\n", "Sources/app.swift": "print(1)\n"])
            defer { tui.tearDown() }

            #expect(await tui.waitFor("README.md"), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" Explorer · Fix the login bug"), "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Explorer")?.bold == true)
            let sources = try #require(row(tui, "▸ Sources/"), "\(tui.text)")
            #expect(sources.style(of: "Sources/")?.inverse == true)
            let readme = try #require(tui.mainPane.firstIndex { $0.text.contains("README.md") })
            #expect(tui.mainPane.firstIndex { $0.text.contains("Sources/") }! < readme)
            #expect(row(tui, "app.swift") == nil)

            await tui.press(.char("l", []))

            #expect(await tui.waitFor("app.swift"), "\(tui.text)")
            #expect(row(tui, "▾ Sources/") != nil, "\(tui.text)")
            let app = try #require(row(tui, "app.swift"))
            #expect(app.text.hasPrefix("     "), "\(app.text)")

            await tui.press(.char("j", []))
            #expect(row(tui, "app.swift")?.style(of: "app.swift")?.inverse == true, "\(tui.text)")

            await tui.press(.char("h", []), .char("h", []))
            #expect(row(tui, "app.swift") == nil, "\(tui.text)")
            #expect(row(tui, "▸ Sources/")?.style(of: "Sources/")?.inverse == true, "\(tui.text)")
        }

        // Enter on a file hands it to `$EDITOR` in the checkout, and the tab comes back.
        @Test func enterOpensAFileInTheEditor() async throws {
            let (tui, alpha) = try await open(["README.md": "hi\n"], editor: "myedit --wait")
            defer { tui.tearDown() }
            #expect(await tui.waitFor("README.md"), "\(tui.text)")

            await tui.press(.enter([]))

            #expect(tui.handoffs.handoffs == [Handoff(arguments: ["myedit", "--wait", alpha.path + "/README.md"],
                                                      directory: alpha.path)])
            #expect(row(tui, "README.md") != nil, "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Explorer")?.bold == true)
        }

        // `/` searches file names as they are typed; Enter opens the match in the editor
        // and leaves the tree open at it.
        @Test func fileNameSearchFindsAndOpensAFile() async throws {
            let (tui, alpha) = try await open(["README.md": "", "Sources/App.swift": "", "Sources/MyApp.swift": ""])
            defer { tui.tearDown() }
            #expect(await tui.waitFor("README.md"), "\(tui.text)")

            await tui.press(.char("/", []))
            await tui.type("app")

            #expect(await tui.waitFor("Sources/MyApp.swift"), "\(tui.text)")
            #expect(row(tui, "Find a file: app") != nil, "\(tui.text)")
            #expect(row(tui, "Sources/App.swift")?.style(of: "Sources/App.swift")?.inverse == true, "\(tui.text)")
            #expect(row(tui, "README.md") == nil)
            // Typing takes the number keys too.
            #expect(tui.topBar[2].style(of: "Explorer")?.bold == true)

            await tui.press(.enter([]))

            #expect(tui.handoffs.handoffs.map(\.arguments) == [["myedit", alpha.path + "/Sources/App.swift"]])
            #expect(await tui.waitFor("App.swift"), "\(tui.text)")
            #expect(row(tui, "▾ Sources/") != nil, "\(tui.text)")
            #expect(row(tui, "App.swift")?.style(of: "App.swift")?.inverse == true, "\(tui.text)")
            #expect(row(tui, "Find a file") == nil)
        }

        // F finds text in files: Enter searches, the lines are listed under their files,
        // and Enter on one opens the editor at that line.
        @Test func findInFilesListsLinesAndOpensTheEditorAtOne() async throws {
            let (tui, alpha) = try await open(["a.swift": "let one = 1\nlet token = 2\n", "b.txt": "token\n"],
                                              editor: "vim")
            defer { tui.tearDown() }
            #expect(await tui.waitFor("a.swift"), "\(tui.text)")

            await tui.press(.char("F", []))
            await tui.type("token")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("2 matches in 2 files"), "\(tui.text)")
            #expect(row(tui, "Find in files: token") != nil, "\(tui.text)")
            #expect(row(tui, "   2  let token = 2") != nil, "\(tui.text)")
            #expect(row(tui, "   1  token") != nil, "\(tui.text)")
            #expect(row(tui, "let token = 2")?.style(of: "let token = 2")?.inverse == true, "\(tui.text)")

            await tui.press(.enter([]))

            #expect(tui.handoffs.handoffs.map(\.arguments) == [["vim", "+2", alpha.path + "/a.swift"]])

            await tui.press(.escape)
            #expect(row(tui, "Find in files") == nil, "\(tui.text)")
            #expect(row(tui, "b.txt") != nil, "\(tui.text)")
        }

        // n makes a file with the name typed, R renames the picked one, and D asks before
        // moving it to the Trash.
        @Test func createsRenamesAndTrashesFiles() async throws {
            let (tui, alpha) = try await open(["kept.txt": ""])
            defer { tui.tearDown() }
            #expect(await tui.waitFor("kept.txt"), "\(tui.text)")
            let folder = alpha.url

            await tui.press(.char("n", []))
            #expect(row(tui, "New file:") != nil, "\(tui.text)")
            await tui.type("draft.md")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("draft.md"), "\(tui.text)")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("draft.md").path))
            #expect(row(tui, "draft.md")?.style(of: "draft.md")?.inverse == true, "\(tui.text)")

            await tui.press(.char("R", []))
            #expect(row(tui, "Rename: draft.md") != nil, "\(tui.text)")
            await tui.press(.char("u", .ctrl))
            await tui.type("notes.md")
            await tui.press(.enter([]))

            #expect(await tui.waitFor("notes.md"), "\(tui.text)")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("draft.md").path))
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))

            await tui.press(.char("D", []))
            #expect(tui.contains("Move notes.md to the Trash?"), "\(tui.text)")
            #expect(tui.contains("File can be restored"), "\(tui.text)")
            await tui.press(.char("y", []))

            #expect(await waitUntil { !tui.contains("notes.md") }, "\(tui.text)")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))
            #expect(row(tui, "kept.txt") != nil)

            // A name already taken is refused, in the tab's own words.
            await tui.press(.char("n", []))
            await tui.type("kept.txt")
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Something called kept.txt is already in this folder."), "\(tui.text)")
        }
    }
}
