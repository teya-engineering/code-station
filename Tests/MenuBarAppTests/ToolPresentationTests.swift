import Foundation
import Testing
@testable import MenuBarApp

struct ToolPresentationTests {
    @Test func findsAChangeInsideLargeSharedSections() throws {
        let prefix = (0..<20_000).map { "shared-prefix-\($0)" }
        let suffix = (0..<10).map { "shared-suffix-\($0)" }
        let old = (prefix + ["old value"] + suffix).joined(separator: "\n")
        let new = (prefix + ["new value"] + suffix).joined(separator: "\n")
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/source.swift",
            "old_string": old,
            "new_string": new
        ])
        let tool = ToolUse(id: "large-edit", name: "Edit",
                           input: String(decoding: input, as: UTF8.self))

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.added == 1)
        #expect(presentation.removed == 1)
        #expect(presentation.changes[0].lines.map(\.kind)
                == [.context, .context, .deletion, .addition, .context, .context])
        #expect(presentation.changes[0].lines.map(\.text) == [
            "shared-prefix-19998", "shared-prefix-19999", "old value", "new value",
            "shared-suffix-0", "shared-suffix-1"
        ])
    }

    @Test func numbersAnEditFromWhereItLandedInTheFile() throws {
        let old = ["beta", "gamma"].joined(separator: "\n")
        let new = ["beta", "GAMMA", "delta"].joined(separator: "\n")
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/source.swift",
            "old_string": old,
            "new_string": new
        ])
        var tool = ToolUse(id: "placed-edit", name: "Edit",
                           input: String(decoding: input, as: UTF8.self))
        tool.editStartLine = 40

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        // "beta" is shared, so line 40 is context and the change starts on line 41. The
        // removed line is numbered in the old file, the added ones in the new.
        #expect(presentation.changes[0].lines.map(\.kind) == [.context, .deletion, .addition, .addition])
        #expect(presentation.changes[0].lines.map(\.number) == [40, 41, 41, 42])
    }

    @Test func leavesADiffUnnumberedWhenNothingSaysWhereItLanded() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/source.swift",
            "old_string": "one",
            "new_string": "two"
        ])
        let tool = ToolUse(id: "unplaced-edit", name: "Edit",
                           input: String(decoding: input, as: UTF8.self))

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.changes[0].lines.allSatisfy { $0.number == nil })
    }

    @Test func readsCodexsUnifiedDiffWithTheNumbersItCarries() throws {
        let unified = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,3 +10,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        @@ -40,2 +40,3 @@
         let c = 4
        +let d = 5
        """
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/Sources/App.swift",
            "diff": unified
        ])
        let tool = ToolUse(id: "codex-edit", name: "Edit",
                           input: String(decoding: input, as: UTF8.self))

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.added == 2)
        #expect(presentation.removed == 1)
        #expect(presentation.argument == "Sources/App.swift")
        #expect(presentation.changes[0].lines.map(\.kind)
                == [.context, .deletion, .addition, .gap, .context, .addition])
        #expect(presentation.changes[0].lines.map(\.number) == [10, 11, 11, nil, 40, 41])
        #expect(presentation.changes[0].lines.map(\.text)
                == ["let a = 1", "let b = 2", "let b = 3", "", "let c = 4", "let d = 5"])
    }

    @Test func stillNamesACodexEditWrittenBeforeItCarriedArguments() {
        let tool = ToolUse(id: "old-codex-edit", name: "Edit",
                           input: "update Sources/App.swift")

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == "update Sources/App.swift")
        #expect(presentation.changes.isEmpty)
    }

    @Test func keepsAHomeDirectorySiblingAbsolute() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let file = "\(home)-archive/source.swift"
        let input = try JSONSerialization.data(withJSONObject: ["file_path": file])
        let tool = ToolUse(id: "outside-home", name: "Read",
                           input: String(decoding: input, as: UTF8.self))

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == file)
    }

    @Test func presentsAPlainCodexShellCommand() {
        let tool = ToolUse(id: "codex-command", name: "Bash",
                           input: "swift test --filter ToolPresentationTests")

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == "swift test --filter ToolPresentationTests")
        #expect(presentation.label == "Bash · swift test --filter ToolPresentationTests")
    }

    @Test func foldsAMultilineCodexShellCommandOntoOneLine() {
        let tool = ToolUse(id: "codex-script", name: "Bash",
                           input: "swift build\n  swift test")

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == "swift build swift test")
    }

    // MARK: - What a call wrote without saying so

    @Test func drawsAShellCommandsChangeOneFileAtATime() {
        let patch = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -3,3 +3,3 @@
         intro
        -old line
        +new line
        diff --git a/docs/guide.md b/docs/guide.md
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/docs/guide.md
        @@ -0,0 +1,2 @@
        +first
        +second

        """
        var tool = ToolUse(id: "shell-write", name: "Bash",
                           input: #"{"command":"cat > docs/guide.md <<'EOF'\nfirst\nEOF"}"#)
        tool.written = WrittenChange(files: 2, added: 3, removed: 1, patch: patch)

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.added == 3)
        #expect(presentation.removed == 1)
        #expect(presentation.changedFiles == 2)
        #expect(presentation.changes.map(\.name) == ["README.md", "docs/guide.md"])
        #expect(presentation.changes[0].lines.map(\.kind) == [.context, .deletion, .addition])
        #expect(presentation.changes[0].lines.map(\.number) == [3, 4, 4])
        #expect(presentation.changes[1].lines.map(\.text) == ["first", "second"])
        #expect(presentation.changes[1].added == 2)
        // The command is still what the row opens: the diff was measured off the tree
        // rather than sent with the call.
        #expect(!presentation.diffIsTheInput)
    }

    @Test func namesAFileAShellCommandDeleted() {
        let patch = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 4444444..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two

        """
        var tool = ToolUse(id: "shell-delete", name: "Bash", input: #"{"command":"rm gone.txt"}"#)
        tool.written = WrittenChange(files: 1, added: 0, removed: 2, patch: patch)

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.changes.map(\.name) == ["gone.txt"])
        #expect(presentation.changes[0].removed == 2)
    }

    @Test func readsAPatchWhoseOwnContentLooksLikeAPatch() {
        let patch = """
        diff --git a/sample.diff b/sample.diff
        index 5555555..6666666 100644
        --- a/sample.diff
        +++ b/sample.diff
        @@ -1,2 +1,3 @@
         diff --git a/x b/x
        +++ b/x
        -- a/x

        """
        var tool = ToolUse(id: "nested-patch", name: "Bash", input: #"{"command":"apply"}"#)
        tool.written = WrittenChange(files: 1, added: 1, removed: 1, patch: patch)

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        // One file, not three: a header only counts before the hunks begin.
        #expect(presentation.changes.map(\.name) == ["sample.diff"])
        // The first character of each line is its marker, so what is left of "+++ b/x" is
        // the two characters after it.
        #expect(presentation.changes[0].lines.map(\.text)
                == ["diff --git a/x b/x", "++ b/x", "- a/x"])
    }

    @Test func keepsTheCountsOfAChangeTooLargeToDraw() {
        var tool = ToolUse(id: "huge-write", name: "Bash",
                           input: #"{"command":"npm install"}"#)
        tool.written = WrittenChange(files: 400, added: 90_000, removed: 0)

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.changes.isEmpty)
        #expect(presentation.changedFiles == 400)
        #expect(presentation.added == 90_000)
        // What came back matters far less than what it wrote, so the row says the change.
        #expect(!presentation.notesResultLineCount)
    }

    @Test func leavesACommandThatChangedNothingAsACommand() {
        let tool = ToolUse(id: "read-only", name: "Bash", input: #"{"command":"ls"}"#)

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.changes.isEmpty)
        #expect(presentation.added == nil)
        #expect(presentation.notesResultLineCount)
    }

    // MARK: - Placing an edit in its file

    @Test func findsTheLineAnEditLandedOn() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-location-\(UUID().uuidString).swift")
        try (1...6).map { "line \($0)" }.joined(separator: "\n").write(
            to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": file.path,
            "old_string": "line 3",
            "new_string": "line 3\nline 4"
        ])

        #expect(EditLocation.startLine(name: "Edit",
                                       input: String(decoding: input, as: UTF8.self)) == 3)
    }

    @Test func placesAWrittenFileAtItsFirstLine() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/brand-new.swift",
            "content": "anything"
        ])

        #expect(EditLocation.startLine(name: "Write",
                                       input: String(decoding: input, as: UTF8.self)) == 1)
    }

    @Test func placesNothingWhenTheFileNoLongerHoldsWhatWasWritten() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": "/tmp/project/missing-\(UUID().uuidString).swift",
            "old_string": "one",
            "new_string": "two"
        ])

        #expect(EditLocation.startLine(name: "Edit",
                                       input: String(decoding: input, as: UTF8.self)) == nil)
    }
}
