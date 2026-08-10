import AppKit
import SwiftUI

private let menuMinimumWidth: CGFloat = 170

// The right-click menu, drawn by the app rather than by AppKit. The system menu cannot
// be styled and arrives in the system's own font and colours, so it reads as a piece of
// another program sitting on top of this one; this menu uses the same palette, type and
// rows as the rest of the window, the way the in-app dialog does.
enum MenuEntry {
    case item(MenuItem)
    case cards([MenuCardItem])
    case separator

    static func item(_ label: String,
                     kind: MenuItem.Kind = .plain,
                     icon: String? = nil,
                     checked: Bool = false,
                     showsUpdate: Bool = false,
                     badge: String? = nil,
                     badgeTint: Color? = nil,
                     subtitle: String? = nil,
                     detail: String? = nil,
                     detailColour: Color? = nil,
                     action: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, kind: kind, icon: icon, checked: checked,
                       showsUpdate: showsUpdate,
                       badge: badge, badgeTint: badgeTint, subtitle: subtitle,
                       detail: detail, detailColour: detailColour, handler: action))
    }
}

struct MenuCardItem {
    let label: String
    let icon: String
    var showsBeta = false
    var showsUpdate = false
    let detail: String
    var detailColour: Color?
    var handler: () -> Void = {}
}

struct MenuItem {
    enum Kind { case plain, destructive }

    let label: String
    var kind: Kind = .plain
    // An optional leading symbol for menus whose entries create different kinds of thing.
    // The host reserves the column for every row once one entry uses it.
    var icon: String?
    // Marks the row that is currently in force, for menus that pick one of a set.
    var checked = false
    var showsUpdate = false
    // A small type chip before the label, for menus that add one of several kinds of
    // thing and want the kind readable before the words.
    var badge: String?
    var badgeTint: Color?
    // A second line under the label saying what picking the row does, so the mechanism
    // is explained at the moment of choosing.
    var subtitle: String?
    // Trailing state on the row - a count, an environment, a shortcut - so a menu of
    // places can say how each one is doing without being opened.
    var detail: String?
    var detailColour: Color?
    var handler: () -> Void = {}
}

// Holds whatever menu is open, along with the point it was asked for. It lives at the
// top of the window so the menu can spill past the panel it was opened from.
@MainActor
@Observable
final class MenuPresenter {
    private(set) var entries: [MenuEntry] = []
    private(set) var origin: CGPoint = .zero
    // Set when the menu should take the width of the control that opened it rather
    // than the width of its own rows, so it reads as an extension of that control.
    private(set) var width: CGFloat?
    // Lets a menu wider than its control stay attached to the control's trailing edge.
    // A right-click menu has no control edge and still flips to the left of the click.
    private(set) var trailingAnchor: CGFloat?
    // Changes on every open so the host can drop the size it measured for the last menu.
    private(set) var generation = 0

    var isOpen: Bool { !entries.isEmpty }

    @discardableResult
    func show(_ entries: [MenuEntry], at point: CGPoint, width: CGFloat? = nil,
              trailingAnchor: CGFloat? = nil) -> Int {
        self.entries = entries
        origin = point
        self.width = width.map { max($0, menuMinimumWidth) }
        self.trailingAnchor = trailingAnchor
        generation += 1
        return generation
    }

    func replaceEntries(_ entries: [MenuEntry], ifGeneration generation: Int) {
        guard isOpen, self.generation == generation else { return }
        self.entries = entries
    }

    func dismiss() { entries = [] }

    // The item runs after the menu is gone, so an action that opens a dialog is not
    // left sitting behind a menu.
    func run(_ item: MenuItem) {
        entries = []
        item.handler()
    }

    func run(_ item: MenuCardItem) {
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
    // same menu opens from a plain click and hangs under the button. A button sitting
    // at the bottom of the window can anchor the menu to its top edge instead, and
    // matching the width makes the menu read as the button unfolding. A refresh keeps
    // slow external state current without delaying the menu opening.
    func appMenu(edge: VerticalEdge = .bottom,
                 matchWidth: Bool = false,
                 refreshOnOpen: (() async -> Void)? = nil,
                 _ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(AppMenuButton(edge: edge, matchWidth: matchWidth,
                               refreshOnOpen: refreshOnOpen, entries: entries))
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
    let edge: VerticalEdge
    let matchWidth: Bool
    let refreshOnOpen: (() async -> Void)?
    let entries: () -> [MenuEntry]

    @State private var anchor = MenuAnchor()

    func body(content: Content) -> some View {
        content
            .background(MenuAnchorView(anchor: anchor))
            .contentShape(Rectangle())
            .onTapGesture {
                guard let placement = anchor.placement(edge: edge) else { return }
                let generation = presenter.show(
                    entries(),
                    at: placement.origin,
                    width: matchWidth ? placement.width : nil,
                    trailingAnchor: placement.trailingEdge)
                guard let refreshOnOpen else { return }
                Task { @MainActor in
                    await refreshOnOpen()
                    presenter.replaceEntries(entries(), ifGeneration: generation)
                }
            }
    }
}

// A menu hangs off the button that opened it: from its bottom left, or from its top left
// for a button at the foot of the window, where the host's edge flip then lands the menu
// above the button. It is measured the same way a right-click is, so both kinds of menu
// land in the same coordinate space.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func placement(edge: VerticalEdge) -> (origin: CGPoint, width: CGFloat,
                                            trailingEdge: CGFloat)? {
        guard let view, let content = view.window?.contentView else { return nil }
        let frame = view.convert(view.bounds, to: content)
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        let bottom = content.isFlipped ? frame.maxY : content.bounds.height - frame.minY
        let y = edge == .bottom ? bottom + 4 : top - 4
        return (CGPoint(x: frame.minX, y: y), frame.width, frame.maxX)
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
                        // A menu opened to a fixed width keeps it; anything else takes
                        // the width its own rows ask for.
                        .fixedSize(horizontal: presenter.width == nil, vertical: true)
                        .frame(width: presenter.width)
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
        let hasIcons = presenter.entries.contains {
            if case .item(let item) = $0 { return item.icon != nil }
            return false
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presenter.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    MenuItemRow(item: item, checkColumn: hasChecks, iconColumn: hasIcons) {
                        presenter.run(item)
                    }
                case .cards(let items):
                    MenuCardGrid(items: items) { presenter.run($0) }
                case .separator:
                    Divider()
                        .overlay(Theme.hairline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: menuMinimumWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    // A menu near an edge stays attached to its control when it has one. A right-click
    // menu instead flips over the click, which is what the system menu does too.
    private func x(in bounds: CGSize) -> CGFloat {
        let flipped = presenter.origin.x + size.width > bounds.width - 8
            ? (presenter.trailingAnchor ?? presenter.origin.x) - size.width
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

private struct MenuCardGrid: View {
    let items: [MenuCardItem]
    let action: (MenuCardItem) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MenuCardItemView(item: item) { action(item) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct MenuCardItemView: View {
    let item: MenuCardItem
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.accent.opacity(0.10)))
                    Spacer(minLength: 4)
                    if item.showsUpdate {
                        UpdateIndicator()
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: .semibold))
                    if item.showsBeta {
                        Text("beta")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .baselineOffset(4)
                    }
                }
                    .lineLimit(1)

                Text(item.detail)
                    .font(.mono(10))
                    .foregroundStyle(item.detailColour.map(AnyShapeStyle.init)
                                     ?? AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(hovering ? Color.black.opacity(0.055) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let checkColumn: Bool
    let iconColumn: Bool
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
                if iconColumn {
                    Image(systemName: item.icon ?? "square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                        .opacity(item.icon == nil ? 0 : 1)
                }
                if let badge = item.badge {
                    let tint = item.badgeTint ?? Color.secondary
                    Text(badge)
                        .font(.mono(9, .bold))
                        .kerning(0.5)
                        .foregroundStyle(tint)
                        .padding(.vertical, 3)
                        // One width for every chip, so the labels line up in a column.
                        .frame(width: 48)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.12)))
                        .padding(.trailing, 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: 13, weight: item.subtitle == nil ? .regular : .semibold))
                        if item.showsUpdate {
                            UpdateIndicator()
                        }
                    }
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = item.detail {
                    Spacer(minLength: 24)
                    Text(detail)
                        .font(.mono(11))
                        .foregroundStyle(item.detailColour.map(AnyShapeStyle.init)
                                         ?? AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(item.kind == .destructive ? Theme.deletion : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, item.subtitle == nil ? 6 : 8)
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
