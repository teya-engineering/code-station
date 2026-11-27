import AppKit
import SwiftUI

struct FileReference: Equatable, Hashable {
    let url: URL
    let line: Int?
    let fragment: String?

    var name: String { url.lastPathComponent }
    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    var destination: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = line.map { "L\($0)" } ?? fragment
        return components.url!
    }

    func explorerRoot(in roots: [String]) -> String? {
        roots.filter { root in
            let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return url.path.pathRelative(to: canonical).map { !$0.isEmpty } ?? false
        }.max {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.count
                < URL(fileURLWithPath: $1).resolvingSymlinksInPath().path.count
        }
    }

    func explorerBlockedReason(in roots: [String]) -> String? {
        if explorerRoot(in: roots) == nil { return "Outside this worktree" }
        if !FileManager.default.fileExists(atPath: url.path) { return "File is unavailable" }
        return nil
    }

    @MainActor
    func reveal(note: (String, String) -> Void) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            note("Revealed \(name) in Finder", "folder")
        } else {
            openFolder(note: note)
        }
    }

    @MainActor
    func openFolder(note: (String, String) -> Void) {
        let opened = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        note(opened ? "Opened the containing folder" : "Could not open the containing folder", "folder")
    }

    @MainActor
    func copyPath(note: (String, String) -> Void) {
        let copied = Pasteboard.copy(url.path)
        note(copied ? "Copied the path" : "Could not copy. The path is available in the header.",
             copied ? "checkmark" : "exclamationmark.triangle")
    }
}

struct FileReferenceAction {
    let accepts: (URL) -> Bool
    let perform: (URL, CGRect?) -> Void
}

@MainActor
struct FileReferenceActions {
    let reference: FileReference
    let roots: [String]
    let dialogs: DialogPresenter
    let textScale: CGFloat
    let openExplorer: (URL) -> Bool
    let note: (String, String) -> Void

    func entries(origin: @escaping () -> CGRect?) -> [MenuEntry] {
        let reason = reference.explorerBlockedReason(in: roots)
        return [
            .fileSubject(reference.url.path),
            .item("Preview", kind: .primary, icon: "eye") { preview(from: origin()) },
            .item("Open in Explorer", icon: "folder", disabled: reason != nil, help: reason) { open() },
            .separator,
            .item("Reveal in Finder", icon: "arrow.up.forward.app") { reference.reveal(note: note) },
            .item("Copy path", icon: "doc.on.doc") { reference.copyPath(note: note) }
        ]
    }

    func open() {
        if !openExplorer(reference.destination) {
            note("This file is no longer available in Explorer", "exclamationmark.triangle")
        }
    }

    func preview(from origin: CGRect?) {
        var dialog = Dialog(title: reference.name, actions: [])
        dialog.content = AnyView(FileReferencePreview(reference: reference, roots: roots,
                                                     origin: origin, openExplorer: openExplorer)
            .environment(\.textScale, textScale))
        dialog.width = FileReferenceMetrics.dialogWidth
        dialog.maximumHeight = FileReferenceMetrics.dialogHeight
        dialog.isModal = true
        dialog.framesItself = true
        dialog.fitsWindow = true
        dialogs.show(dialog)
    }
}
