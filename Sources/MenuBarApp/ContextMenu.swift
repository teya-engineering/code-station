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
                     projectTint: Theme.ProjectTint? = nil,
                     icon: String? = nil,
                     image: NSImage? = nil,
                     imageShape: MenuItem.ImageShape = .circle,
                     checked: Bool = false,
                     showsUpdate: Bool = false,
                     badge: String? = nil,
                     badgeTint: Color? = nil,
                     subtitle: String? = nil,
                     monospacedSubtitle: Bool = false,
                     detail: String? = nil,
                     detailColour: Color? = nil,
                     action: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, kind: kind, projectTint: projectTint,
                       icon: icon, image: image,
                       imageShape: imageShape, checked: checked,
                       showsUpdate: showsUpdate,
                       badge: badge, badgeTint: badgeTint, subtitle: subtitle,
                       monospacedSubtitle: monospacedSubtitle,
                       detail: detail, detailColour: detailColour,
                       handler: action))
    }

    static func item(_ label: String,
                     icon: String? = nil,
                     image: NSImage? = nil,
                     imageShape: MenuItem.ImageShape = .circle,
                     badge: String? = nil,
                     badgeTint: Color? = nil,
                     subtitle: String? = nil,
                     detail: String,
                     detailColour: Color? = nil,
                     detailAction: @escaping () -> Void) -> MenuEntry {
        .item(MenuItem(label: label, icon: icon, image: image, imageShape: imageShape,
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
    enum ImageShape { case circle, tile }

    let label: String
    var kind: Kind = .plain
    // The colour of the thing the row belongs to, for menus whose entries are spread
    // across several projects and where the name alone does not say which.
    var projectTint: Theme.ProjectTint?
    // An optional leading symbol for menus whose entries create different kinds of thing.
    // The host reserves the column for every row once one entry uses it.
    var icon: String?
    var image: NSImage?
    var imageShape: ImageShape = .circle
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
    // Set when the subtitle is something typed at a shell rather than a sentence, so it
    // is read as the literal text it has to be.
    var monospacedSubtitle = false
    // Trailing state on the row - a count, an environment, a shortcut - so a menu of
    // places can say how each one is doing without being opened.
    var detail: String?
    var detailColour: Color?
    var detailHandler: (() -> Void)? = nil
    var handler: (() -> Void)? = nil

    func matches(_ filter: String) -> Bool {
        let query = filter.trimmed
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

    @State private var anchor = FrameAnchor()
    // The menu this button opened, so the button can tell its own menu from the one
    // another control has since opened.
    @State private var opened: Int?

    private var isOpen: Bool { presenter.isOpen && presenter.generation == opened }

    func body(content: Content) -> some View {
        Button(action: open) {
            content
                .environment(\.menuIsOpen, isOpen)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FrameAnchorView(anchor: anchor))
    }

    // The menu hangs off the requested edge of the button. Both edges are passed on so
    // the host can use the other side when the menu does not fit.
    private func open() {
        guard let frame = anchor.frame() else { return }
        let generation = presenter.show(
            entries(),
            at: CGPoint(x: frame.minX, y: edge == .bottom ? frame.maxY + 4 : frame.minY - 4),
            width: matchWidth ? frame.width : nil,
            trailingAnchor: frame.maxX,
            verticalAttachment: .control(
                edge: edge, oppositeY: edge == .bottom ? frame.minY - 4 : frame.maxY + 4))
        opened = generation
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

extension EnvironmentValues {
    // True on the label of a menu button while the menu it opened is on screen, so a
    // control can show that the open menu is its own.
    @Entry var menuIsOpen = false
}

// The mark on a control that hangs a menu under itself. It turns over while the menu is
// open, so the pill and the menu read as one thing unfolding.
struct MenuChevron: View {
    var size: CGFloat = 9
    var tint: Color = .secondary

    @Environment(\.menuIsOpen) private var open

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(open ? 180 : 0))
            .motion(Motion.reveal, value: open)
    }
}

// MARK: - Host

struct ContextMenuHost: View {
    @Environment(MenuPresenter.self) private var presenter

    @State private var measurement = OverlayMeasurement()

    private var size: CGSize { measurement.size }

    var body: some View {
        ZStack {
            if presenter.isOpen {
                content
            }
        }
        .motion(Motion.reveal, value: presenter.isOpen)
    }

    private var content: some View {
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
                    .measuredOverlay(generation: presenter.generation, into: $measurement)
                    .offset(x: x(in: geometry.size), y: y(in: geometry.size))
                    .transition(opening)

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

    // The menu grows out of the edge it is attached to, so it unfolds from its control
    // rather than landing on top of the window. It leaves without the scale: a menu on
    // its way out is already behind whatever the click started.
    private var opening: AnyTransition {
        let anchor: UnitPoint = switch presenter.verticalAttachment {
        case .control(edge: .top, oppositeY: _): .bottom
        default: .top
        }
        return .asymmetric(insertion: .scale(scale: 0.97, anchor: anchor).combined(with: .opacity),
                           removal: .opacity)
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
        let hasTints = items.contains { $0.projectTint != nil }
        let hasIcons = items.contains { $0.icon != nil || $0.image != nil }
        let hasCheckedIcons = items.contains {
            $0.checked && ($0.icon != nil || $0.image != nil)
        }
        // A check and an icon share one slot unless a row needs to show both.
        let usesSharedMarkColumn = hasChecks && hasIcons && !hasCheckedIcons

        return MenuContentScrollView(maxHeight: maxHeight) {
            menuContent(hasChecks: hasChecks,
                        hasIcons: hasIcons,
                        hasTints: hasTints,
                        usesSharedMarkColumn: usesSharedMarkColumn)
        }
        .frame(minWidth: menuMinimumWidth, alignment: .leading)
        .floatingCard(cornerRadius: 11)
    }

    private func menuContent(hasChecks: Bool,
                             hasIcons: Bool,
                             hasTints: Bool,
                             usesSharedMarkColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presenter.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    MenuItemRow(item: item,
                                checkColumn: hasChecks,
                                iconColumn: hasIcons,
                                tintColumn: hasTints,
                                usesSharedMarkColumn: usesSharedMarkColumn,
                                action: item.handler == nil ? nil : { presenter.run(item) },
                                detailAction: item.detailHandler == nil
                                    ? nil : { presenter.runDetail(item) })
                        .transition(.fadeIn)
                case .searchable(let searchable):
                    SearchableMenuItemsView(searchable: searchable,
                                            checkColumn: hasChecks,
                                            iconColumn: hasIcons,
                                            tintColumn: hasTints,
                                            usesSharedMarkColumn: usesSharedMarkColumn)
                        .transition(.fadeIn)
                case .cards(let items):
                    MenuCardGrid(items: items) { presenter.run($0) }
                        .transition(.fadeIn)
                case .separator:
                    Divider()
                        .overlay(Theme.hairline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .transition(.fadeIn)
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

// A single content tree keeps the search field and its rows alive while the filter
// changes. Measuring the document rather than fixing the scroll view at its ideal size
// lets a short menu hug its rows while a long one stays clipped inside its viewport.
struct MenuContentScrollView<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content

    @State private var contentHeight: CGFloat?

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuContentHeightKey.self,
                                           value: geometry.size.height)
                })
        }
        .scrollIndicators(.visible)
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
        .clipped()
        .onPreferenceChange(MenuContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    let tintColumn: Bool
    let usesSharedMarkColumn: Bool

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
            .fieldSurface()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if items.isEmpty {
                Text(searchable.noResults)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.fadeIn)
            } else {
                ForEach(items, id: \.index) { indexed in
                    MenuItemRow(item: indexed.item,
                                checkColumn: checkColumn,
                                iconColumn: iconColumn,
                                tintColumn: tintColumn,
                                usesSharedMarkColumn: usesSharedMarkColumn,
                                action: indexed.item.handler == nil
                                    ? nil : { presenter.run(indexed.item) },
                                detailAction: indexed.item.detailHandler == nil
                                    ? nil : { presenter.runDetail(indexed.item) })
                        .transition(.fadeIn)
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
            .surface(hovering ? Color.black.opacity(0.055) : Theme.field, cornerRadius: 9)
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
    let tintColumn: Bool
    let usesSharedMarkColumn: Bool
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
        .motion(Motion.hover, value: hovering)
    }

    private var row: some View {
        HStack(spacing: 7) {
            // The column is kept for every row once one entry uses it, so a row with
            // nothing to say about where it belongs still lines up with the ones that do.
            if tintColumn {
                ProjectDot(tint: item.projectTint ?? .blank, size: 6)
            }
            if checkColumn && !usesSharedMarkColumn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .opacity(item.checked ? 1 : 0)
            }
            if iconColumn {
                if usesSharedMarkColumn && item.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                } else if let image = item.image {
                    menuImage(image)
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
                        .font(item.monospacedSubtitle ? .mono(10.5) : .system(size: 11))
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

    @ViewBuilder
    private func menuImage(_ image: NSImage) -> some View {
        let content = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: 22, height: 22)

        switch item.imageShape {
        case .circle:
            content.clipShape(Circle())
        case .tile:
            content.clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
        onClick?(FrameAnchor.fromTop(point, in: content))
    }
}
