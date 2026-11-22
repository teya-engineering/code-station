import Foundation
import Testing
@testable import MenuBarApp

struct ExplorerSearchTests {

    @Test func matchesNamesBeforeContainingDirectories() {
        let root = "/project"
        let files = [
            node("/project/search/Other.swift"),
            node("/project/SearchPanel.swift"),
            node("/project/Search.swift"),
            node("/project/MySearchTests.swift")
        ]

        let result = FileNameSearch.matches("search", in: files, beneath: root)

        #expect(result.map(\.name) == [
            "Search.swift", "SearchPanel.swift", "MySearchTests.swift", "Other.swift"
        ])
    }

    @Test func matchesPathsWithoutCaseOrAccents() {
        let files = [node("/project/Résources/Preview.PNG")]

        let result = FileNameSearch.matches("resources/pre", in: files, beneath: "/project")

        #expect(result.map(\.name) == ["Preview.PNG"])
    }

    @Test func emptyQueriesHaveNoMatches() {
        #expect(FileNameSearch.matches("  ", in: [node("/project/File.swift")],
                                             beneath: "/project").isEmpty)
    }

    @Test func detectsTwoNearbyShiftTaps() {
        var detector = ShiftDoubleTapDetector()

        let first = detector.registerTap(at: 10)
        let second = detector.registerTap(at: 10.4)
        let nextFirst = detector.registerTap(at: 10.6)

        #expect(!first)
        #expect(second)
        #expect(!nextFirst)
    }

    @Test func ignoresSlowOrInterruptedTaps() {
        var detector = ShiftDoubleTapDetector()

        let first = detector.registerTap(at: 10)
        let slowSecond = detector.registerTap(at: 11)
        detector.reset()
        let interruptedSecond = detector.registerTap(at: 11.1)

        #expect(!first)
        #expect(!slowSecond)
        #expect(!interruptedSecond)
    }

    private func node(_ path: String) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(url: url, name: url.lastPathComponent,
                        isDirectory: false, size: 0, modified: nil)
    }
}
