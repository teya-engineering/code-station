import AppKit
import SwiftUI
import CodeStationCore

enum ExplorerSplitLayout {
    static let defaultTreeWidth: CGFloat = 300
    static let minimumTreeWidth: CGFloat = 220
    static let minimumDetailWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let handleWidth: CGFloat = 9

    static func treeWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let paneWidth = max(0, availableWidth - dividerWidth)
        let halfWidth = paneWidth / 2
        let minimum = min(minimumTreeWidth, halfWidth)
        let maximum = max(minimum, paneWidth - min(minimumDetailWidth, halfWidth))
        return min(max(proposedWidth, minimum), maximum)
    }
}

struct ExplorerFileShortcuts: NSViewRepresentable {
    let enabled: Bool
    let onCopy: () -> Bool
    let onPaste: () -> Bool
    let onTrash: () -> Bool
    let onRename: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, onCopy: onCopy, onPaste: onPaste, onTrash: onTrash,
                    onRename: onRename)
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.enabled = enabled
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
        context.coordinator.onTrash = onTrash
        context.coordinator.onRename = onRename
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var enabled: Bool
        var onCopy: () -> Bool
        var onPaste: () -> Bool
        var onTrash: () -> Bool
        var onRename: () -> Bool

        private var token: Any?

        init(enabled: Bool, onCopy: @escaping () -> Bool, onPaste: @escaping () -> Bool,
             onTrash: @escaping () -> Bool, onRename: @escaping () -> Bool) {
            self.enabled = enabled
            self.onCopy = onCopy
            self.onPaste = onPaste
            self.onTrash = onTrash
            self.onRename = onRename
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated { self.handle(event) }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard enabled, anchor?.window === NSApp.keyWindow else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Return renames and Cmd+Delete moves to the Trash, as they do in Finder.
            if modifiers.isEmpty, event.keyCode == 36 { return onRename() }
            guard modifiers == .command else { return false }
            if event.keyCode == 51 { return onTrash() }
            return switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopy()
            case "v": onPaste()
            default: false
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
