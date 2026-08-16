import AppKit
import SwiftUI

private let menuMinimumWidth: CGFloat = 170
// A row takes the width its own text asks for, so a subtitle carrying something long -
// a shell command, a path, a URL - would otherwise drag the whole menu across the window.
private let menuSubtitleMaximumWidth: CGFloat = 360

// The right-click menu, drawn by the app rather than by AppKit. The system menu cannot
// be styled and arrives in the system's own font and colours, so it reads as a piece of
// another program sitting on top of this one; this menu uses the same palette, type and
// rows as the rest of the window, the way the in-app dialog does.
enum MenuEntry {
    case item(MenuItem)
    case searchable(SearchableMenuItems)
    case cards([MenuCardItem])
    case separator

    static func item(_ label: String,
                     kind: MenuItem.Kind = .plain,
                     icon: String? = nil,
                     image: NSImage? = nil,
                     checked: Bool = false,
                     showsUpdate: Bool = false,
                     badge: String? = nil,
                     badgeTint: Color? = nil,
                     subtitle: String? = nil,
                     detail: String? = nil,
                     detailColour: Color? = nil,
                     action: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, kind: kind, icon: icon, image: image, checked: checked,
                       showsUpdate: showsUpdate,
                       badge: badge, badgeTint: badgeTint, subtitle: subtitle,
                       detail: detail, detailColour: detailColour,
                       handler: action))
    }

    static func item(_ label: String,
                     icon: String? = nil,
                     image: NSImage? = nil,
                     badge: String? = nil,
                     badgeTint: Color? = nil,
                     subtitle: String? = nil,
                     detail: String,
                     detailColour: Color? = nil,
                     detailAction: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, icon: icon, image: image,
                       badge: badge, badgeTint: badgeTint, subtitle: subtitle,
                       detail: detail, detailColour: detailColour,
                       detailHandler: detailAction))
    }

    static func searchable(_ items: [MenuItem],
                           prompt: String,
                           noResults: String) -> MenuEntry {
        .searchable(SearchableMenuItems(items: items, prompt: prompt,
                                        noResults: noResults))
    }
}

struct SearchableMenuItems {
    let items: [MenuItem]
    let prompt: String
    let noResults: String
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
    var image: NSImage?
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
    var detailHandler: (() -> Void)? = nil
    var handler: (() -> Void)? = nil

    func matches(_ filter: String) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return label.localizedCaseInsensitiveContains(query)
            || subtitle?.localizedCaseInsensitiveContains(query) == true
    }
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
    private(set) var verticalAttachment: MenuVerticalAttachment = .point
    // Changes on every open so the host can drop the size it measured for the last menu.
    private(set) var generation = 0
    // A refresh can replace an open menu without opening a new generation. Its own key
    // lets the host animate any size change while keeping the same anchor and focus.
    private(set) var contentRevision = 0

    var isOpen: Bool { !entries.isEmpty }

    @discardableResult
    func show(_ entries: [MenuEntry], at point: CGPoint, width: CGFloat? = nil,
              trailingAnchor: CGFloat? = nil,
              verticalAttachment: MenuVerticalAttachment = .point) -> Int {
        self.entries = entries
        origin = point
        self.width = width.map { max($0, menuMinimumWidth) }
        self.trailingAnchor = trailingAnchor
        self.verticalAttachment = verticalAttachment
        generation += 1
        contentRevision += 1
        return generation
    }

    func replaceEntries(_ entries: [MenuEntry], ifGeneration generation: Int) {
        guard isOpen, self.generation == generation else { return }
        self.entries = entries
        contentRevision += 1
    }

    func dismiss() { entries = [] }

    // The item runs after the menu is gone, so an action that opens a dialog is not
    // left sitting behind a menu.
    func run(_ item: MenuItem) {
        guard let handler = item.handler else { return }
        entries = []
        handler()
    }

    func runDetail(_ item: MenuItem) {
        guard let handler = item.detailHandler else { return }
        entries = []
        handler()
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
        Button(action: open) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
    }

    private func open() {
        guard let placement = anchor.placement(edge: edge) else { return }
        let generation = presenter.show(
            entries(),
            at: placement.origin,
            width: matchWidth ? placement.width : nil,
            trailingAnchor: placement.trailingEdge,
            verticalAttachment: .control(edge: edge, oppositeY: placement.oppositeY))
        guard let refreshOnOpen else { return }
        Task { @MainActor in
            await refreshOnOpen()
            presenter.replaceEntries(entries(), ifGeneration: generation)
        }
    }
}

enum MenuVerticalAttachment {
    case point
    case control(edge: VerticalEdge, oppositeY: CGFloat)

    func y(originY: CGFloat, menuHeight: CGFloat, boundsHeight: CGFloat) -> CGFloat {
        let inset: CGFloat = 8
        let lowerEdge = boundsHeight - inset
        let proposed: CGFloat
        switch self {
        case .point:
            proposed = originY + menuHeight > lowerEdge ? originY - menuHeight : originY
        case .control(edge: .top, let oppositeY):
            let above = originY - menuHeight
            proposed = above >= inset ? above : oppositeY
        case .control(edge: .bottom, let oppositeY):
            proposed = originY + menuHeight <= lowerEdge ? originY : oppositeY - menuHeight
        }
        return max(inset, min(proposed, boundsHeight - menuHeight - inset))
    }
}

// A menu hangs off the requested edge of the button that opened it. Both button edges
// are kept so the host can use the other side when the menu does not fit.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func placement(edge: VerticalEdge) -> (origin: CGPoint, width: CGFloat,
                                            trailingEdge: CGFloat,
                                            oppositeY: CGFloat)? {
        guard let view, let content = view.window?.contentView else { return nil }
        let frame = view.convert(view.bounds, to: content)
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        let bottom = content.isFlipped ? frame.maxY : content.bounds.height - frame.minY
        let y = edge == .bottom ? bottom + 4 : top - 4
        let oppositeY = edge == .bottom ? top - 4 : bottom + 4
        return (CGPoint(x: frame.minX, y: y), frame.width, frame.maxX, oppositeY)
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

                    card(maxHeight: max(0, geometry.size.height - 16))
                        // A menu opened to a fixed width keeps it; anything else takes
                        // the width its own rows ask for.
                        .fixedSize(horizontal: presenter.width == nil, vertical: false)
                        .frame(width: presenter.width)
                        .id(presenter.generation)
                        .smoothlyResizes(when: presenter.contentRevision)
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

    private func card(maxHeight: CGFloat) -> some View {
        // Rows only make room for a checkmark when the menu has one, so a plain menu is
        // not indented for a mark that never appears.
        let items = presenter.entries.flatMap { entry -> [MenuItem] in
            switch entry {
            case .item(let item): [item]
            case .searchable(let searchable): searchable.items
            case .cards, .separator: []
            }
        }
        let hasChecks = items.contains(where: \.checked)
        let hasIcons = items.contains { $0.icon != nil || $0.image != nil }

        return ViewThatFits(in: .vertical) {
            menuContent(hasChecks: hasChecks, hasIcons: hasIcons)
                .fixedSize(horizontal: false, vertical: true)

            // Only the menu that has to scroll takes the height it was given. A frame
            // grows to its maximum, so capping the whole card would draw every short
            // menu as a window-tall panel with its rows floating in the middle of it.
            ScrollView {
                menuContent(hasChecks: hasChecks, hasIcons: hasIcons)
            }
            .scrollIndicators(.visible)
            .frame(height: maxHeight)
        }
        .frame(minWidth: menuMinimumWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    private func menuContent(hasChecks: Bool, hasIcons: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presenter.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    MenuItemRow(item: item,
                                checkColumn: hasChecks,
                                iconColumn: hasIcons,
                                action: item.handler == nil ? nil : { presenter.run(item) },
                                detailAction: item.detailHandler == nil
                                    ? nil : { presenter.runDetail(item) })
                        .transition(.reveal)
                case .searchable(let searchable):
                    SearchableMenuItemsView(searchable: searchable,
                                            checkColumn: hasChecks,
                                            iconColumn: hasIcons)
                        .transition(.reveal)
                case .cards(let items):
                    MenuCardGrid(items: items) { presenter.run($0) }
                        .transition(.reveal)
                case .separator:
                    Divider()
                        .overlay(Theme.hairline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .transition(.reveal)
                }
            }
        }
        .padding(.vertical, 6)
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
        presenter.verticalAttachment.y(originY: presenter.origin.y,
                                       menuHeight: size.height,
                                       boundsHeight: bounds.height)
    }
}

private struct SearchableMenuItemsView: View {
    private struct IndexedItem {
        let index: Int
        let item: MenuItem
    }

    let searchable: SearchableMenuItems
    let checkColumn: Bool
    let iconColumn: Bool

    @Environment(MenuPresenter.self) private var presenter
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var items: [IndexedItem] {
        searchable.items.enumerated().compactMap { index, item in
            item.matches(filter) ? IndexedItem(index: index, item: item) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField(searchable.prompt, text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($filterFocused)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if items.isEmpty {
                Text(searchable.noResults)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.reveal)
            } else {
                ForEach(items, id: \.index) { indexed in
                    MenuItemRow(item: indexed.item,
                                checkColumn: checkColumn,
                                iconColumn: iconColumn,
                                action: indexed.item.handler == nil
                                    ? nil : { presenter.run(indexed.item) },
                                detailAction: indexed.item.detailHandler == nil
                                    ? nil : { presenter.runDetail(indexed.item) })
                        .transition(.reveal)
                }
            }
        }
        .smoothlyResizes(when: items.map(\.index))
        .task {
            await Task.yield()
            filterFocused = true
        }
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
    let action: (() -> Void)?
    let detailAction: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .onHover { hovering = $0 }
    }

    private var row: some View {
        HStack(spacing: 7) {
            if checkColumn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .opacity(item.checked ? 1 : 0)
            }
            if iconColumn {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: item.icon ?? "square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .opacity(item.icon == nil ? 0 : 1)
                }
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: menuSubtitleMaximumWidth, alignment: .leading)
                }
            }
            if let detail = item.detail {
                Spacer(minLength: 24)
                if let detailAction {
                    ActionButton(title: detail, tone: .danger, height: 26, size: 11,
                                 action: detailAction)
                } else {
                    Text(detail)
                        .font(.mono(11))
                        .foregroundStyle(item.detailColour.map(AnyShapeStyle.init)
                                         ?? AnyShapeStyle(.tertiary))
                }
            }
        }
        .foregroundStyle(item.kind == .destructive ? Theme.deletion : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, item.subtitle == nil ? 6 : 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(action != nil && hovering ? Color.black.opacity(0.05) : .clear)
            .padding(.horizontal, 5))
        .contentShape(Rectangle())
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
