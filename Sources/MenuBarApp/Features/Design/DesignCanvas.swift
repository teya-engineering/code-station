import SwiftUI

// What a canvas is showing: the design's files on disk, the screens they make up, and
// which one is on view. The agent writes those files behind the app's back and nothing
// announces the change, so whichever pane shows a design keeps one of these and polls it.
@MainActor
@Observable
final class DesignCanvas {
    private(set) var revision: DesignArtifactRevision?
    private(set) var manifest = DesignManifest.singleScreen
    private(set) var selectedScreenID = DesignScreen.canvas.id
    // Counted up to load the same files again.
    private(set) var reloadGeneration = 0

    var selectedScreen: DesignScreen? {
        manifest.screens.first { $0.id == selectedScreenID } ?? manifest.screens.first
    }

    func screenURL(in directory: URL) -> URL? {
        selectedScreen.flatMap { DesignManifest.safeURL(for: $0, in: directory) }
    }

    var screenMenu: [MenuEntry] {
        manifest.screens.map { screen in
            .item(screen.title, icon: "rectangle", checked: screen.id == selectedScreenID,
                  subtitle: screen.path) { self.selectedScreenID = screen.id }
        }
    }

    func reload() { reloadGeneration += 1 }

    func select(_ screenID: String) {
        guard manifest.screens.contains(where: { $0.id == screenID }) else { return }
        selectedScreenID = screenID
    }

    func refresh(_ directory: URL) {
        let next = DesignArtifactRevision.read(directory)
        if next != revision { revision = next }
        let nextManifest = DesignManifest.read(from: directory)
        if nextManifest != manifest {
            manifest = nextManifest
            if !manifest.screens.contains(where: { $0.id == selectedScreenID }) {
                selectedScreenID = manifest.screens.first?.id ?? DesignScreen.canvas.id
            }
        }
    }

    // Runs until it is cancelled, so it belongs in a task keyed on the directory.
    func watch(_ directory: URL) async {
        while !Task.isCancelled {
            refresh(directory)
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }
    }
}

// The bar over a canvas: what the pane calls it on the left, and on the right the screen
// picker when the design has more than one screen, the pane's own tools, and a reload.
struct DesignCanvasBar<Leading: View, Tools: View>: View {
    let canvas: DesignCanvas
    @ViewBuilder let leading: Leading
    @ViewBuilder let tools: Tools

    var body: some View {
        HStack(spacing: Space.md) {
            leading
            Spacer(minLength: 10)
            if canvas.manifest.screens.count > 1 {
                OptionMenu(value: canvas.selectedScreen?.title ?? "Screen", matchWidth: false) {
                    canvas.screenMenu
                }
                .fixedSize()
            }
            tools
            if canvas.revision != nil {
                GlyphButton(icon: "arrow.clockwise", side: ControlHeight.md, tint: Theme.accent) {
                    canvas.reload()
                }
                .appTooltip("Reload canvas")
            }
        }
        .canvasBar()
    }
}

extension View {
    // The strip of tools over a page in the pane. A design's canvas and a running app both
    // sit under one, so they read as the same kind of page.
    func canvasBar() -> some View {
        padding(.horizontal, 14)
            .frame(height: DesignSplitLayout.barHeight)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
    }
}
