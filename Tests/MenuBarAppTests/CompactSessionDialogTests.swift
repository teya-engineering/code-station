import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct CompactSessionDialogTests {
    @Test func keepsOtherImpactDialogsAtTheirExistingSize() {
        let dialog = Dialog.impact("Delete project?", rows: [], action: "Delete") {}
        #expect(dialog.width == 500)
        #expect(dialog.impact?.compact == false)
    }

    @Test func cancellationDoesNotRunDeletion() {
        let presenter = DialogPresenter()
        var deleted = false
        let dialog = Dialog.impact("Delete this session?", rows: [], compact: true,
                                   action: "Delete session") { deleted = true }
        presenter.show(dialog)
        presenter.dismiss()
        #expect(presenter.current == nil)
        #expect(!deleted)
        presenter.show(dialog)
        presenter.run(dialog.actions.last!)
        #expect(presenter.current == nil)
        #expect(!deleted)
        presenter.show(dialog)
        presenter.run(dialog.actions.first!)
        #expect(deleted)
    }

    @Test func rendersCompactDialog() throws {
        guard let folder = ProcessInfo.processInfo.environment["COMPACT_DIALOG_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for dark in [false, true] {
            for height in [CGFloat(760), 300] {
                let presenter = DialogPresenter()
                presenter.show(.impact("Delete this session?",
                    message: "this is too big. seems disproportionate to the rest of the app",
                    subject: .init(name: "Code Station", kind: .workspace),
                    rows: [.init(title: "Conversation history", detail: "Removed from Code Station."),
                           .init(title: "3 worktrees", detail: "Removed from disk. Branches are kept if they have unmerged commits.")],
                    warning: "Conversation history cannot be restored.", compact: true,
                    action: "Delete session and worktrees") {})
                let host = NSHostingView(rootView: Theme.background.overlay { DialogHost() }
                    .environment(presenter)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 700, height: height)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("dialog-\(dark)-\(Int(height)).png"))
            }
        }
    }
}
