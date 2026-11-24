import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

struct ChangeReceiptTests {
    private typealias File = SecondOpinionAskFacts.File

    private func file(_ path: String, _ added: Int = 10, _ removed: Int = 2, root: String = "/repo") -> File {
        File(root: root, path: path, added: added, removed: removed)
    }

    // A branch spread over fourteen folders, shaped like a real one in this repository.
    private var branch: [File] {
        let app = "Sources/MenuBarApp/"
        let changes = (0..<19).map { file(app + "Features/Changes/Change\($0).swift", 100 - $0 * 4, 20) }
        let controls = ["DayField", "FocusBoundary", "LegacySegment", "Choices", "Toggles"]
            .map { file(app + "DesignSystem/Controls/\($0).swift", 40, 10) }
        let layout = ["ComparisonRange", "CleanupStrips", "Structure", "DataChips"]
            .map { file(app + "DesignSystem/Layout/\($0).swift", 20, 5) }
        let motion = ["HeaderMotion", "Motion"].map { file(app + "DesignSystem/Motion/\($0).swift", 10, 4) }
        let tokens = ["Tokens", "Appearance"].map { file(app + "DesignSystem/\($0).swift", 9, 3) }
        let tests = (0..<10).map { file("Tests/MenuBarAppTests/Test\($0).swift", 60, 15) }
        let settings = ["SecondOpinionSettingsView", "SettingsView"].map { file(app + "Features/Settings/\($0).swift", 60, 70) }
        let design = (0..<4).map { file(app + "Features/Design/Design\($0).swift", 30, 18) }
        let agents = (0..<3).map { file(app + "Infrastructure/Agents/Runner\($0).swift", 40, 11) }
        let docs = [file("docs/adrs/0034-review-scope.md", 41, 0), file("docs/adrs/0031-second-opinion.md", 22, 14),
                    file("docs/design-system.md", 8, 3)]
        let navigation = ["SidebarNotices", "GlobalCommandPalette", "AppSidebar"]
            .map { file(app + "App/Navigation/\($0).swift", 5, 3) }
        let scripts = [file("Scripts/design-rules-baseline.txt", 0, 7), file("Scripts/check-design-rules.sh", 3, 1)]
        return changes + controls + layout + motion + tokens + tests + settings + design + agents + docs
            + navigation + [file(app + "App/RootView.swift", 1, 1)] + scripts
    }

    @Test func aSmallReviewStaysFlatAndABigOneIsGrouped() {
        let twelve = (0..<12).map { file("src/File\($0).swift") }
        #expect(ChangeReceipt(files: twelve).isFlat)
        #expect(!ChangeReceipt(files: twelve + [file("src/More.swift")]).isFlat)
    }

    @Test func closeFoldersMergeFirstUntilAFewRowsAreLeft() {
        let receipt = ChangeReceipt(files: branch)
        let titles = receipt.folders.map(\.title)

        #expect(receipt.folders.count == ChangeReceipt.folderLimit)
        #expect(titles.first == "Sources/MenuBarApp/Features/Changes")
        // The design system's sub-folders and the app's navigation fold into their parents,
        // while the features stay apart because each is big on its own.
        let designSystem = receipt.folders.first { $0.title == "Sources/MenuBarApp/DesignSystem" }
        #expect(designSystem?.files.count == 13)
        #expect(receipt.folders.first { $0.title == "Sources/MenuBarApp/App" }?.files.count == 4)
        #expect(titles.contains("Sources/MenuBarApp/Features/Settings"))
        #expect(titles.contains("docs/adrs") && titles.contains("docs"))
        #expect(!titles.contains { $0.hasSuffix("DesignSystem/Controls") })
        #expect(receipt.folders.reduce(0) { $0 + $1.files.count } == branch.count)
        #expect(zip(receipt.folders, receipt.folders.dropFirst()).allSatisfy { $0.lines >= $1.lines })
    }

    @Test func aFolderNamesItsFilesFromInsideIt() throws {
        let receipt = ChangeReceipt(files: branch)
        let designSystem = try #require(receipt.folders.first { $0.title == "Sources/MenuBarApp/DesignSystem" })
        let dayField = try #require(designSystem.files.first { $0.name == "DayField.swift" })

        #expect(designSystem.name(of: dayField) == "Controls/DayField.swift")
        #expect(receipt.folder(of: dayField)?.id == designSystem.id)
        #expect(zip(designSystem.files, designSystem.files.dropFirst()).allSatisfy { $0.lines >= $1.lines })
    }

    @Test func theRootMostFilesShareIsFaded() {
        #expect(ChangeReceipt(files: branch).sharedRoot == "Sources/MenuBarApp/")
        // Spread evenly, nothing is shared by most files.
        let spread = (0..<14).map { file("module\($0 % 7)/File\($0).swift") }
        #expect(ChangeReceipt(files: spread).sharedRoot == nil)
    }

    @Test func filesAtTheTopAndInOtherRepositoriesAreNamed() {
        let one = ChangeReceipt(files: [file("README.md"), file("src/App.swift")])
        #expect(Set(one.folders.map(\.title)) == ["Top level", "src"])
        #expect(one.folders.first { $0.title == "Top level" }?.name(of: file("README.md")) == "README.md")

        let two = ChangeReceipt(files: [file("README.md", root: "/work/api"), file("src/App.swift", root: "/work/web")],
                                repositoryNames: ["/work/api": "api", "/work/web": "web"])
        #expect(Set(two.folders.map(\.title)) == ["api", "web/src"])
    }

    @Test func theFilterSearchesEveryFileLargestFirst() {
        let receipt = ChangeReceipt(files: branch)
        let matches = receipt.matching("  secondopinion ")

        #expect(matches.map(\.path) == ["Sources/MenuBarApp/Features/Settings/SecondOpinionSettingsView.swift"])
        // Features/Design, the design system, the design doc and both design-rule scripts.
        #expect(receipt.matching("DESIGN").count == 4 + 13 + 1 + 2)
        #expect(receipt.matching("").count == branch.count)
        #expect(receipt.matching("nothing like this").isEmpty)
    }

    @MainActor @Test func theMapFillsItsWidthAndKeepsEverySliceVisible() {
        let groups = [
            ChangeMap.Group(id: "a", label: "a", slices: [.init(id: "a1", title: "a/1", added: 900, removed: 100),
                                                          .init(id: "a2", title: "a/2", added: 0, removed: 0)]),
            ChangeMap.Group(id: "b", label: "b", slices: [.init(id: "b1", title: "b/1", added: 1, removed: 0)])
        ]
        let layout = ChangeMap.layout(groups, width: 300)

        #expect(layout.slices.count == 3)
        #expect(layout.slices.allSatisfy { $0.width >= ChangeMap.minimumSlice })
        let last = layout.slices[2]
        #expect(abs(last.x + last.width - 300) < 0.001)
        #expect(abs(layout.slices[1].x - (layout.slices[0].x + layout.slices[0].width + ChangeMap.sliceGap)) < 0.001)
        #expect(abs(layout.spans[1].x - (layout.spans[0].x + layout.spans[0].width + ChangeMap.groupGap)) < 0.001)
        #expect(ChangeMap.layout([], width: 300).slices.isEmpty)
    }

    @MainActor @Test func theListKeepsOneHeightHoweverBigTheBranch() {
        func height(of files: [File]) -> CGFloat {
            var height: CGFloat = 0
            let list = SecondOpinionChangeList(receipt: ChangeReceipt(files: files), filter: .constant(""), open: { _ in })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .frame(width: ReviewMetrics.askWidth - Space.pane * 2)
                .environment(TooltipPresenter())
            let host = NSHostingView(rootView: list)
            host.frame = NSRect(x: 0, y: 0, width: ReviewMetrics.askWidth, height: 1200)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return height
        }
        let sixty = height(of: branch)
        let wider = height(of: branch + (0..<140).map { file("Sources/MenuBarApp/Features/Changes/More\($0).swift") })

        #expect(sixty > ReviewMetrics.receiptListHeight)
        #expect(abs(sixty - wider) < 1, "\(sixty) vs \(wider)")
        // A flat list of a few files hugs its rows rather than holding the full height.
        #expect(height(of: Array(branch.prefix(5))) < ControlHeight.md * 6)
    }
}
