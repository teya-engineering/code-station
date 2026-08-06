import AppKit
import SwiftUI

// The right-click menu, drawn by the app rather than by AppKit. The system menu cannot
// be styled and arrives in the system's own font and colours, so it reads as a piece of
// another program sitting on top of this one; this menu uses the same palette, type and
// rows as the rest of the window, the way the in-app dialog does.
enum MenuEntry {
    case item(MenuItem)
    case separator

    static func item(_ label: String,
                     kind: MenuItem.Kind = .plain,
                     checked: Bool = false,
                     action: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, kind: kind, checked: checked, handler: action))
    }
}

struct MenuItem {
    enum Kind { case plain, destructive }

    let label: String
    var kind: Kind = .plain
    // Marks the row that is currently in force, for menus that pick one of a set.
    var checked = false
    var handler: () -> Void = {}
}

// Holds whatever menu is open, along with the point it was asked for. It lives at the
// top of the window so the menu can spill past the panel it was opened from.
@MainActor
@Observable
final class MenuPresenter {
    private(set) var entries: [MenuEntry] = []
    private(set) var origin: CGPoint = .zero
    // Changes on every open so the host can drop the size it measured for the last menu.
    private(set) var generation = 0

    var isOpen: Bool { !entries.isEmpty }

    func show(_ entries: [MenuEntry], at point: CGPoint) {
        self.entries = entries
        origin = point
        generation += 1
    }

    func dismiss() { entries = [] }

    // The item runs after the menu is gone, so an action that opens a dialog is not
    // left sitting behind a menu.
    func run(_ item: MenuItem) {
        entries = []
        item.handler()
    }
}

extension View {
    // The entries are built when the menu opens, so they can read state that has moved
    // on since the view was laid out.
    func appContextMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(AppContextMenu(entries: entries))
    }

    // Some controls are a menu button rather than a row with a menu behind it, so the
    // same menu opens from a plain click and hangs under the button.
    func appMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(AppMenuButton(entries: entries))
    }
}

private struct AppContextMenu: ViewModifier {
    @Environment(MenuPresenter.self) private var presenter
    let entries: () -> [MenuEntry]

    func body(content: Content) -> some View {
        content.overlay(RightClickCatcher { point in
            presenter.show(entries(), at: point)
        })
    }
}

private struct AppMenuButton: ViewModifier {
    @Environment(MenuPresenter.self) private var presenter
    let entries: () -> [MenuEntry]

    @State private var anchor = MenuAnchor()

    func body(content: Content) -> some View {
        content
            .background(MenuAnchorView(anchor: anchor))
            .contentShape(Rectangle())
            .onTapGesture {
                guard let point = anchor.menuOrigin() else { return }
                presenter.show(entries(), at: point)
            }
    }
}

// A menu hangs under the button that opened it, so the point it opens at is the button's
// bottom left. It is measured the same way a right-click is, so both kinds of menu land
// in the same coordinate space.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func menuOrigin() -> CGPoint? {
        guard let view, let content = view.window?.contentView else { return nil }
        let frame = view.convert(view.bounds, to: content)
        let bottom = content.isFlipped ? frame.maxY : content.bounds.height - frame.minY
        return CGPoint(x: frame.minX, y: bottom + 4)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

// Only there to be measured, so it takes no clicks of its own.
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Host

struct ContextMenuHost: View {
    @Environment(MenuPresenter.self) private var presenter

    @State private var measurement = MenuMeasurement()

    private var size: CGSize { measurement.size }

    var body: some View {
        if presenter.isOpen {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Swallows the click that dismisses the menu so it does not also
                    // land on whatever is underneath.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }

                    card
                        .fixedSize()
                        // The measurement carries the menu it was taken for, so two
                        // menus that happen to be the same size still each report one,
                        // and a report that arrives late cannot pass itself off as a
                        // measurement of the menu that is open now.
                        .background(GeometryReader { card in
                            Color.clear.preference(
                                key: MenuSizeKey.self,
                                value: MenuMeasurement(generation: presenter.generation,
                                                       size: card.size))
                        })
                        // Read here, on the card's own chain: the catcher and the escape
                        // button next to it in the stack carry the key's default value,
                        // and a read above them would take a default over the card's
                        // measurement.
                        .onPreferenceChange(MenuSizeKey.self) { measurement = $0 }
                        .offset(x: x(in: geometry.size), y: y(in: geometry.size))
                        // Placing the menu needs its size, which is only known once it
                        // has been laid out. Hiding it for that one pass avoids a frame
                        // in the wrong corner.
                        .opacity(measurement.generation == presenter.generation ? 1 : 0)

                    // Escape closes the menu, the way a menu is expected to behave when
                    // the mouse is not involved.
                    Button("", action: presenter.dismiss)
                        .buttonStyle(.plain)
                        .opacity(0)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .ignoresSafeArea()
        }
    }

    private var card: some View {
        // Rows only make room for a checkmark when the menu has one, so a plain menu is
        // not indented for a mark that never appears.
        let hasChecks = presenter.entries.contains {
            if case .item(let item) = $0 { return item.checked }
            return false
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presenter.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    MenuItemRow(item: item, checkColumn: hasChecks) { presenter.run(item) }
                case .separator:
                    Divider()
                        .overlay(Theme.hairline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    // A menu opened near an edge flips back over the click rather than hanging off the
    // window, which is what the system menu does too.
    private func x(in bounds: CGSize) -> CGFloat {
        let flipped = presenter.origin.x + size.width > bounds.width - 8
            ? presenter.origin.x - size.width
            : presenter.origin.x
        return max(8, min(flipped, bounds.width - size.width - 8))
    }

    private func y(in bounds: CGSize) -> CGFloat {
        let flipped = presenter.origin.y + size.height > bounds.height - 8
            ? presenter.origin.y - size.height
            : presenter.origin.y
        return max(8, min(flipped, bounds.height - size.height - 8))
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let checkColumn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if checkColumn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                        .opacity(item.checked ? 1 : 0)
                }
                Text(item.label)
                    .font(.system(size: 13))
            }
            .foregroundStyle(item.kind == .destructive ? Theme.deletion : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.black.opacity(0.05) : .clear)
                .padding(.horizontal, 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuMeasurement: Equatable {
    var generation = -1
    var size = CGSize.zero
}

private struct MenuSizeKey: PreferenceKey {
    static let defaultValue = MenuMeasurement()

    // Views that never set the key still hand their default to the reduce, so the newest
    // real measurement wins rather than whichever value happens to come last.
    static func reduce(value: inout MenuMeasurement,
                       nextValue: () -> MenuMeasurement) {
        let next = nextValue()
        if next.generation > value.generation { value = next }
    }
}

// MARK: - Catching the click

// SwiftUI has no right-click gesture, so an invisible AppKit view sits over the row and
// reports where the click landed.
private struct RightClickCatcher: NSViewRepresentable {
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
    }
}

private final class CatcherView: NSView {
    var onClick: ((CGPoint) -> Void)?

    // Only the right button belongs to this view. Everything else has to fall straight
    // through to the row underneath, which still owns selection, hover and dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, isMenuClick(event) else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { report(event) }

    override func mouseDown(with event: NSEvent) {
        guard isMenuClick(event) else { return super.mouseDown(with: event) }
        report(event)
    }

    // AppKit asks for a menu on right-click and would put up its own if given one.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func isMenuClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: true
        case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
        default: false
        }
    }

    private func report(_ event: NSEvent) {
        guard let content = window?.contentView else { return }
        let point = content.convert(event.locationInWindow, from: nil)
        // AppKit measures an unflipped view from the bottom of the window, SwiftUI
        // always from the top.
        onClick?(CGPoint(x: point.x,
                         y: content.isFlipped ? point.y : content.bounds.height - point.y))
    }
}
