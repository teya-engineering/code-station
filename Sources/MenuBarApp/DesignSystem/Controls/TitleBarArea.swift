import AppKit
import SwiftUI

// The window keeps only a thin real title bar, and the band under it looks like part of
// the same strip. This lets the empty parts of that band act like a title bar as well: a
// double-click does what System Settings asks for, and a drag moves the window. Anything
// drawn on top of the band, such as a button or a tab, still takes its own clicks first.
struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarAreaView { TitleBarAreaView() }
    func updateNSView(_ view: TitleBarAreaView, context: Context) {}
}

final class TitleBarAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isTitleBar ? super.hitTest(point) : nil
    }

    // A real title bar can be dragged while the window is in the background, so this can too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            TitleBarDoubleClick.current().perform(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    // Only a band along the top edge of a window stands in for its title bar. The same band
    // lower down a pane, or at the top of a sheet, is just a heading.
    var isTitleBar: Bool {
        guard let window, window.sheetParent == nil,
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen)
        else { return false }
        let top = convert(bounds, to: nil).maxY
        return abs(top - window.contentLayoutRect.maxY) < 1
    }
}

// The thin real title bar above the band. With its title hidden and drawn clear, AppKit
// does not zoom on a double-click there, so the window answers it the same way the band
// does. The traffic lights keep their own clicks.
final class TitleBarWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, isInTitleBarStrip(event.locationInWindow) {
            TitleBarDoubleClick.current().perform(on: self)
            return
        }
        super.sendEvent(event)
    }

    private func isInTitleBarStrip(_ point: NSPoint) -> Bool {
        guard !styleMask.contains(.fullScreen), point.y >= contentLayoutRect.maxY else { return false }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { standardWindowButton($0) }
        return !buttons.contains { $0.convert($0.bounds, to: nil).contains(point) }
    }
}

// What the user picked under Desktop & Dock for a double-click on a title bar.
enum TitleBarDoubleClick: Equatable {
    case zoom
    case minimize
    case nothing

    static func current(_ defaults: UserDefaults = .standard) -> Self {
        reading(action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                minimizes: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }

    static func reading(action: String?, minimizes: Bool) -> Self {
        switch action {
        case "Minimize": .minimize
        case "None": .nothing
        case nil:
            // Older systems kept only this switch, and zoom was the answer when it was off.
            minimizes ? .minimize : .zoom
        // "Fill" has no public call of its own, and zoom also grows the window to the screen.
        default: .zoom
        }
    }

    @MainActor func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .nothing: break
        }
    }
}
