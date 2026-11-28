import Foundation
import Testing
@testable import MenuBarApp

struct AttachProjectSearchTests {
    private let projects = [
        Project(id: UUID(), name: "engineering", path: "/Users/dev/Development/engineering"),
        Project(id: UUID(), name: "Branch whitelist", path: "/Users/dev/Development/branch-whitelist"),
        Project(id: UUID(), name: "design-notes", path: "/Users/dev/Documents/design-notes")
    ]

    @Test func listsEveryProjectUntilSomethingIsTyped() {
        #expect(AttachProjectSearch.matches(projects, query: "") == projects)
        #expect(AttachProjectSearch.matches(projects, query: "   ") == projects)
    }

    @Test func findsAProjectByNameOrFolderWhateverTheCase() {
        #expect(AttachProjectSearch.matches(projects, query: "WHITE").map(\.name) == ["Branch whitelist"])
        #expect(AttachProjectSearch.matches(projects, query: "documents").map(\.name) == ["design-notes"])
        // The order of the list is kept, so the cursor lands where the eye already is.
        #expect(AttachProjectSearch.matches(projects, query: " development ").map(\.name)
            == ["engineering", "Branch whitelist"])
        #expect(AttachProjectSearch.matches(projects, query: "payments").isEmpty)
    }

    @Test func marksOnlyThePartThatMatched() {
        let text = "Branch whitelist"
        let found = try? #require(AttachProjectSearch.range(of: "white", in: text))
        #expect(found.map { String(text[$0]) } == "white")
        #expect(AttachProjectSearch.range(of: "", in: text) == nil)
        #expect(AttachProjectSearch.range(of: "nothing", in: text) == nil)

        let marked = AttachProjectSearch.marked(text, query: "WHITE")
        #expect(String(marked.characters) == text)
        #expect(marked.runs.filter { $0.backgroundColor != nil }
            .map { String(marked[$0.range].characters) } == ["white"])
        #expect(AttachProjectSearch.marked(text, query: "").runs.allSatisfy { $0.backgroundColor == nil })
    }
}
