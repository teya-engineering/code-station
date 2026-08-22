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
        #expect(presentation.diff.map(\.kind)
                == [.context, .context, .deletion, .addition, .context, .context])
        #expect(presentation.diff.map(\.text) == [
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
        #expect(presentation.diff.map(\.kind) == [.context, .deletion, .addition, .addition])
        #expect(presentation.diff.map(\.number) == [40, 41, 41, 42])
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

        #expect(presentation.diff.allSatisfy { $0.number == nil })
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
        #expect(presentation.diff.map(\.kind)
                == [.context, .deletion, .addition, .gap, .context, .addition])
        #expect(presentation.diff.map(\.number) == [10, 11, 11, nil, 40, 41])
        #expect(presentation.diff.map(\.text)
                == ["let a = 1", "let b = 2", "let b = 3", "", "let c = 4", "let d = 5"])
    }

    @Test func stillNamesACodexEditWrittenBeforeItCarriedArguments() {
        let tool = ToolUse(id: "old-codex-edit", name: "Edit",
                           input: "update Sources/App.swift")

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == "update Sources/App.swift")
        #expect(presentation.diff.isEmpty)
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
