import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct WorkspaceExplorerTests {
    @Test func renamingAnInactiveFolderKeepsItsUnsavedFileAndExpansion() {
        let memory = ExplorerMemory()
        let node = FileNode(url: URL(fileURLWithPath: "/attached/Sources/file.swift"),
                            name: "file.swift", isDirectory: false, size: 4)
        memory.remember(.init(expanded: ["/attached/Sources", "/attached/SourcesExtra"], selected: node,
                              unsaved: .init(path: node.path, preview: .text("saved"), draft: "draft",
                                             original: "saved", loadedAt: nil)), for: "/attached")
        memory.moved(from: "/attached/Sources", to: "/attached/Code")
        let place = memory.place(for: "/attached")
        #expect(place?.selected?.path == "/attached/Code/file.swift")
        #expect(place?.expanded == ["/attached/Code", "/attached/SourcesExtra"])
        #expect(place?.unsaved?.path == "/attached/Code/file.swift")
        #expect(place?.unsaved?.draft == "draft")
        #expect(memory.unsavedEdit(inside: "/attached/Code")?.draft == "draft")
        #expect(memory.unsavedEdit(inside: "/attached/Cod") == nil)
        memory.removed("/attached/Code")
        #expect(memory.place(for: "/attached")?.selected == nil)
        #expect(memory.place(for: "/attached")?.unsaved == nil)
        #expect(memory.place(for: "/attached")?.expanded == ["/attached/SourcesExtra"])
    }

    @Test func workspaceWithLongNamesFitsNarrowAndWidePanes() async throws {
        let first = ScratchDirectory(prefix: "workspace-explorer")
        let second = ScratchDirectory(prefix: "workspace-explorer-attached")
        try "# Workspace".write(to: first.path("README.md"), atomically: true, encoding: .utf8)
        let memory = ExplorerMemory()
        let view = ExplorerView(root: first.url.path, repositories: [
            ChangesRepository(root: first.url.path, name: "a-long-lead-project-name"),
            ChangesRepository(root: second.url.path, name: "a-long-attached-project-name")
        ])
        .environment(memory).environment(DialogPresenter()).appOverlays()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.center()
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.layoutIfNeeded()
        if let destination = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
            try await Task.sleep(for: .milliseconds(200))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                hosting.view.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: destination).appendingPathComponent("explorer-\(name).png"))
            }
        }
        for width: CGFloat in [600, 1000] {
            #expect(hosting.sizeThatFits(in: CGSize(width: width, height: 700)).width <= width)
        }
    }
}
