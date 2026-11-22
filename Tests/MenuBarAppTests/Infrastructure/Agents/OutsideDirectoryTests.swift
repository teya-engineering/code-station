import Foundation
import Testing
@testable import MenuBarApp

// Auto mode asks about a call that reaches outside the session's folders, so the folder is
// what the answer is really about. Reading the wrong one out of a command is worse than
// reading none: the card would offer a way into somewhere nobody meant to open up.
struct OutsideDirectoryTests {

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Real folders, because the offer is only made for somewhere that is actually there.
    // They go under /Users/Shared rather than the temporary folder: that one resolves into
    // /private/var, which is a system folder no offer is ever made for, so a checkout there
    // would test the exclusion list instead of the path reading.
    private func withDirectories(_ names: [String],
                                 _ body: (String, [String]) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var made: [String] = []
        for name in names {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            made.append(directory.resolvingSymlinksInPath().path)
        }
        try body(root.resolvingSymlinksInPath().path, made)
    }

    private func bash(_ command: String) -> PermissionRequest {
        request(tool: "Bash", input: ["command": command])
    }

    private func request(tool: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest(
            id: "r", toolName: tool, title: tool,
            subject: input["command"] as? String ?? "",
            detail: "",
            input: try! JSONSerialization.data(withJSONObject: input),
            suggestions: nil, alwaysTitle: nil, questions: [])
    }

    @Test func findsTheFolderACompoundCommandMovesInto() throws {
        try withDirectories(["session", "other"]) { _, made in
            let call = bash("cd \(made[1]) && ls && grep -rn foo . | head -20")
            #expect(call.directoryOutside([made[0]]) == made[1])
        }
    }

    @Test func saysNothingWhenTheFolderIsAlreadyReachable() throws {
        try withDirectories(["session", "other"]) { _, made in
            let call = bash("cd \(made[0])/sub && ls")
            #expect(call.directoryOutside(made) == nil)
        }
    }

    // The folder a compound command works in is the one it moved to, not the first path
    // that happens to be spelled out somewhere later in the line.
    @Test func prefersWhereTheCommandMovesOverWhatItThenReads() throws {
        try withDirectories(["session", "one", "two"]) { _, made in
            let call = bash("cd \(made[2]) && cat \(made[1])/notes.md")
            #expect(call.directoryOutside([made[0]]) == made[2])
        }
    }

    // "2>/dev/null" is on nearly every command the agent writes. Reading it as a folder
    // would put a button offering a way into /dev on almost every card.
    @Test func ignoresRedirectsAndTheSystemFoldersTheyName() throws {
        try withDirectories(["session"]) { _, made in
            let call = bash("grep -rn foo . 2>/dev/null | head -20")
            #expect(call.directoryOutside(made) == nil)
        }
    }

    @Test func neverOffersTheHomeFolderOrAnythingHidden() throws {
        #expect(bash("cd ~ && ls").directoryOutside(["/nowhere"]) == nil)
        #expect(bash("cat ~/.ssh/config").directoryOutside(["/nowhere"]) == nil)
        #expect(bash("cd \(home)/Library && ls").directoryOutside(["/nowhere"]) == nil)
    }

    // A path that is not there yet says nothing about which folder to open up, and a
    // relative one resolves against a folder the session can already see.
    @Test func ignoresPathsThatAreNotThereAndOnesThatAreRelative() throws {
        try withDirectories(["session"]) { root, made in
            #expect(bash("cd \(root)/missing && ls").directoryOutside(made) == nil)
            #expect(bash("cd ../elsewhere && ls").directoryOutside(made) == nil)
        }
    }

    // The file tools name their path outright, so there is nothing to pick out of a line.
    // A file about to be written is not there yet, and the folder around it is still the
    // folder the session is missing.
    @Test func readsThePathAFileToolNamesEvenBeforeTheFileExists() throws {
        try withDirectories(["session", "other"]) { _, made in
            let call = request(tool: "Write", input: ["file_path": made[1] + "/notes.md"])
            #expect(call.directoryOutside([made[0]]) == made[1])
        }
    }

    // A session with no folders of its own has nothing to be outside of.
    @Test func saysNothingWithoutASessionToCompareAgainst() throws {
        try withDirectories(["other"]) { _, made in
            #expect(bash("cd \(made[0]) && ls").directoryOutside([]) == nil)
        }
    }

    // The folder rides back with the answer so it holds for the rest of the turn: the
    // process that asked is the one that has to start seeing it.
    @Test func addingAFolderTravelsBackWithTheAnswer() throws {
        let call = bash("cd /tmp && ls")
        let line = try #require(call.responseLine(.allowAddingDirectory("/somewhere/repo")))
        let envelope = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let response = (envelope["response"] as? [String: Any])?["response"] as? [String: Any]
        let decision = try #require(response)
        let permissions = try #require(decision["updatedPermissions"] as? [[String: Any]])

        #expect(decision["behavior"] as? String == "allow")
        #expect(permissions.first?["type"] as? String == "addDirectories")
        #expect(permissions.first?["directories"] as? [String] == ["/somewhere/repo"])
        #expect(permissions.first?["destination"] as? String == "session")
    }
}
