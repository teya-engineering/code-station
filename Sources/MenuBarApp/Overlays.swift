import AppKit
import SwiftUI

// Dialogs and menus are drawn by the app, so they need somewhere to be drawn. Both are
// placed at the top of whatever they belong to rather than where they were asked for, so
// a question from the sidebar is still centred over the whole window and a menu can spill
// past the panel it was opened from.
//
// A sheet is a separate window stacked over the main one, so the window's own layer is
// underneath it and cannot be seen from inside. Every sheet that asks a question gets a
// layer of its own; each one holds its own presenters, so the dialog appears over the
// thing that asked for it.
extension View {
    func appOverlays() -> some View {
        modifier(AppOverlays())
    }
}

private struct AppOverlays: ViewModifier {
    @State private var dialogs = DialogPresenter()
    @State private var menus = MenuPresenter()
    @State private var tooltips = TooltipPresenter()
    @State private var toolCallDetails = ToolCallDetailPresenter()

    func body(content: Content) -> some View {
        content
            .overlay { ToolCallDetailHost() }
            .overlay { ContextMenuHost() }
            .overlay { TooltipHost() }
            .overlay { DialogHost() }
            .environment(dialogs)
            .environment(menus)
            .environment(tooltips)
            .environment(toolCallDetails)
    }
}

// MARK: - Where a control is

// A menu hangs under the button that opened it and a hint beside the row it belongs to,
// so both need the control's frame in the window's own coordinates. SwiftUI cannot say
// where a view is in the window, so an empty AppKit view rides behind the control and
// is asked instead.
@MainActor
final class FrameAnchor {
    weak var view: NSView?

    // The control's frame in the window, measured from the top the way SwiftUI counts.
    func frame() -> CGRect? {
        guard let view, let content = view.window?.contentView else { return nil }
        return Self.fromTop(view.convert(view.bounds, to: content), in: content)
    }

    // AppKit measures an unflipped view from the bottom of the window, SwiftUI always
    // from the top.
    static func fromTop(_ rect: CGRect, in content: NSView) -> CGRect {
        guard !content.isFlipped else { return rect }
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    static func fromTop(_ point: CGPoint, in content: NSView) -> CGPoint {
        guard !content.isFlipped else { return point }
        return CGPoint(x: point.x, y: content.bounds.height - point.y)
    }
}

struct FrameAnchorView: NSViewRepresentable {
    let anchor: FrameAnchor

    func makeNSView(context: Context) -> NSView {
        let view = MeasuredView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

// Only there to be measured, so it takes no clicks of its own.
private final class MeasuredView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - How big it is

// Placing a menu or a hint needs its size, which is only known once it has been laid
// out. The measurement carries the generation it was taken for, so two that happen to
// be the same size still each report one, and a report that arrives late cannot pass
// itself off as a measurement of what is open now.
struct OverlayMeasurement: Equatable {
    var generation = -1
    var size = CGSize.zero
}

struct OverlaySizeKey: PreferenceKey {
    static let defaultValue = OverlayMeasurement()

    // Views that never set the key still hand their default to the reduce, so the newest
    // real measurement wins rather than whichever value happens to come last.
    static func reduce(value: inout OverlayMeasurement,
                       nextValue: () -> OverlayMeasurement) {
        let next = nextValue()
        if next.generation > value.generation { value = next }
    }
}

extension View {
    // Reports the size laid out for this generation and stays hidden until that report
    // has landed, which avoids a frame in the wrong corner. Read on the measured view's
    // own chain: siblings in a stack carry the key's default value, and a read above
    // them would take a default over the measurement.
    func measuredOverlay(generation: Int,
                         into measurement: Binding<OverlayMeasurement>) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(
                key: OverlaySizeKey.self,
                value: OverlayMeasurement(generation: generation, size: proxy.size))
        })
        .onPreferenceChange(OverlaySizeKey.self) { measurement.wrappedValue = $0 }
        .opacity(measurement.wrappedValue.generation == generation ? 1 : 0)
    }
}
