import CodeStationCore
import Foundation

extension SessionTitle {
    @MainActor
    static func menuEntry(for sessionID: UUID, runner: SessionRunner,
                          store: ProjectStore) -> MenuEntry {
        let generating = runner.isGeneratingTitle(sessionID, store: store)
        let canGenerate = runner.canRegenerateTitle(sessionID, store: store)
        return .item(MenuItem(
            label: generating ? "Generating session title…" : "Regenerate session title",
            icon: "sparkles",
            handler: canGenerate ? { _ = runner.regenerateTitle(sessionID, store: store) } : nil))
    }
}
