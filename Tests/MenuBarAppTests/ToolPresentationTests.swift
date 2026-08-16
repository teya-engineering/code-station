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

    @Test func keepsAHomeDirectorySiblingAbsolute() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let file = "\(home)-archive/source.swift"
        let input = try JSONSerialization.data(withJSONObject: ["file_path": file])
        let tool = ToolUse(id: "outside-home", name: "Read",
                           input: String(decoding: input, as: UTF8.self))

        let presentation = ToolPresentation(tool: tool, projectPath: "/tmp/project")

        #expect(presentation.argument == file)
    }
}
