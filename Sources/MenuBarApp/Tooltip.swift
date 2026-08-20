import AppKit
import SwiftUI

// The hint that appears when the pointer rests on something, drawn by the app rather
// than by AppKit. The system tooltip is a yellow slab in the system's own font that
// cannot be styled, so it reads as a piece of another program sitting on top of this
// one; this one uses the same palette, type and card as the in-app dialog and menu.
//
// It also holds more than a line of text: a sidebar row is truncated to fit a narrow
// rail, so the hint is where the whole title, the path and the numbers behind the row
// can be read without opening it.
struct Tooltip {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    let title: String
    var subtitle: String?
    var note: String?
    var rows: [Row] = []
    var action: (() -> Void)?

    // A hint that is only words needs no panel around it, so it is drawn as a plain line
    // instead.
    var isPlain: Bool { subtitle == nil && note == nil && rows.isEmpty }

    // A whole sentence on one line would run off the side of the window, so past a few
    // words it wraps inside a fixed width rather than hugging its text.
    var wraps: Bool { title.count > 44 }

    // Some hints only have something to say part of the time. Asking for an empty one
    // shows nothing rather than a blank card.
    var isEmpty: Bool {
        title.isEmpty && subtitle == nil && note == nil && rows.isEmpty
    }
}

// Holds whatever hint is up, along with the row it belongs to. It lives at the top of
// the window so a hint asked for by a sidebar row can hang beside the row rather than
// being clipped by the rail it is in.
@MainActor
@Observable
final class TooltipPresenter {
    private static let interactiveDismissalDelay = Duration.milliseconds(250)

    private(set) var current: Tooltip?
    private(set) var anchor: CGRect = .zero
    // Changes on every hint so the host can drop the size it measured for the last one.
    private(set) var generation = 0

    private var owner: UUID?
    @ObservationIgnored private var dismissal: Any?
    @ObservationIgnored private var pendingHide: Task<Void, Never>?

    func show(_ tooltip: Tooltip, from rect: CGRect, owner: UUID) {
        pendingHide?.cancel()
        self.owner = owner
        current = tooltip
        anchor = rect
        generation += 1
        watchForDismissal()
    }

    // Only the row that put a hint up can take it down. Moving the pointer from one row
    // to the next ends the old row's hover after the new one has begun, so a hide that
    // did not check would clear the hint that has just arrived.
    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        guard current?.action != nil else {
            hideAll()
            return
        }
        pendingHide?.cancel()
        pendingHide = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.interactiveDismissalDelay)
            guard !Task.isCancelled else { return }
            hideAll()
        }
    }

    func sourceEntered(owner: UUID) -> Bool {
        guard self.owner == owner, current != nil else { return false }
        pendingHide?.cancel()
        pendingHide = nil
        return true
    }

    func keepInteractiveTooltipVisible() {
        guard current?.action != nil else { return }
        pendingHide?.cancel()
        pendingHide = nil
    }

    func hideInteractiveTooltip() {
        guard current?.action != nil else { return }
        hideAll()
    }

    func hideAll() {
        pendingHide?.cancel()
        pendingHide = nil
        owner = nil
        current = nil
        if let dismissal {
            NSEvent.removeMonitor(dismissal)
            self.dismissal = nil
        }
    }

    // A hint is placed where its row was when the pointer stopped. A click or a scroll
    // moves that row out from under it, so both take the hint away. An interactive hint
    // remains through mouse-down because its button performs the action on mouse-up.
    private func watchForDismissal() {
        guard dismissal == nil else { return }
        dismissal = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                // Removing an interactive hint on mouse-down also removes its button
                // before mouse-up can perform the action.
                if event.type != .leftMouseDown || self?.current?.action == nil {
                    self?.hideAll()
                }
            }
            return event
        }
    }
}

extension View {
    // The hint is built when it is about to be shown, so it can read state that has
    // moved on since the view was laid out.
    func appTooltip(_ tooltip: @escaping () -> Tooltip) -> some View {
        modifier(AppTooltip(tooltip: tooltip))
    }

    // The one-line form, for a control whose icon does not say what it does.
    func appTooltip(_ text: String) -> some View {
        modifier(AppTooltip(tooltip: { Tooltip(title: text) }))
    }
}

private struct AppTooltip: ViewModifier {
    @Environment(TooltipPresenter.self) private var presenter
    let tooltip: () -> Tooltip

    // Long enough that running the pointer across the sidebar puts up nothing, short
    // enough that resting on a row feels answered rather than delayed.
    private static let delay = Duration.milliseconds(450)

    @State private var id = UUID()
    @State private var anchor = TooltipAnchor()
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorView(anchor: anchor))
            // A hint belongs to the pointer resting on something. Rows sliding past
            // under a scroll are not that, and a hint is taken down by a scroll anyway.
            .onPointerHover { inside in
                pending?.cancel()
                guard inside else {
                    presenter.hide(owner: id)
                    return
                }
                guard !presenter.sourceEntered(owner: id) else { return }
                pending = Task {
                    try? await Task.sleep(for: Self.delay)
                    guard !Task.isCancelled, let frame = anchor.frame() else { return }
                    let tooltip = tooltip()
                    guard !tooltip.isEmpty else { return }
                    presenter.show(tooltip, from: frame, owner: id)
                }
            }
            .onDisappear {
                pending?.cancel()
                presenter.hide(owner: id)
            }
    }
}

// MARK: - Where the row is

// The hint hangs beside the row it belongs to, so the row's frame is measured in the
// window's own coordinates the same way a menu's origin is.
@MainActor
private final class TooltipAnchor {
    weak var view: NSView?

    func frame() -> CGRect? {
        guard let view, let content = view.window?.contentView else { return nil }
        let frame = view.convert(view.bounds, to: content)
        if content.isFlipped { return frame }
        // AppKit measures an unflipped view from the bottom of the window, SwiftUI
        // always from the top.
        return CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                      width: frame.width, height: frame.height)
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = TooltipAnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

// Only there to be measured, so it takes no clicks of its own.
private final class TooltipAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Host

struct TooltipHost: View {
    @Environment(TooltipPresenter.self) private var presenter

    // Wide enough for a path or a full session title on two lines, narrow enough that
    // it still reads as a hint rather than a panel.
    private static let width: CGFloat = 260
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 8

    @State private var measurement = TooltipMeasurement()

    private var size: CGSize { measurement.size }

    var body: some View {
        if let tooltip = presenter.current {
            GeometryReader { geometry in
                card(tooltip)
                    // The measurement carries the hint it was taken for, so two hints
                    // that happen to be the same size still each report one: a plain
                    // size would be an unchanged value, and no report at all.
                    .background(GeometryReader { card in
                        Color.clear.preference(
                            key: TooltipSizeKey.self,
                            value: TooltipMeasurement(generation: presenter.generation,
                                                      size: card.size))
                    })
                    .offset(x: x(in: geometry.size), y: y(in: geometry.size))
                    // Placing the hint needs its size, which is only known once it has
                    // been laid out. Hiding it for that one pass avoids a frame in the
                    // wrong corner.
                    .opacity(measurement.generation == presenter.generation ? 1 : 0)
                    .onPreferenceChange(TooltipSizeKey.self) { measurement = $0 }
                    .onHover { inside in
                        if inside {
                            presenter.keepInteractiveTooltipVisible()
                        } else {
                            presenter.hideInteractiveTooltip()
                        }
                    }
                    .allowsHitTesting(tooltip.action != nil)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private func card(_ tooltip: Tooltip) -> some View {
        if let action = tooltip.action {
            Button {
                action()
                presenter.hideAll()
            } label: {
                plainCard(tooltip)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        } else if tooltip.isPlain {
            plainCard(tooltip)
        } else {
            detailedCard(tooltip)
        }
    }

    private func plainCard(_ tooltip: Tooltip) -> some View {
        Text(tooltip.title)
            .font(.system(size: 12))
            .fixedSize(horizontal: !tooltip.wraps, vertical: true)
            .frame(maxWidth: tooltip.wraps ? Self.width : nil, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private func detailedCard(_ tooltip: Tooltip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tooltip.title)
                    .font(.serif(14, .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = tooltip.subtitle {
                    Text(subtitle)
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = tooltip.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !tooltip.rows.isEmpty {
                Divider().overlay(Theme.hairline)
                VStack(spacing: 4) {
                    ForEach(tooltip.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.label.uppercased())
                                .font(.mono(9, .semibold))
                                .kerning(0.5)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(row.value)
                                .font(.mono(10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    // Beside the row rather than under it: the sidebar is a column of rows, and a hint
    // that hangs below covers the next one along. It only falls back to the left when
    // there is no room on the right.
    private func x(in bounds: CGSize) -> CGFloat {
        let right = presenter.anchor.maxX + Self.gap
        let placed = right + size.width > bounds.width - Self.margin
            ? presenter.anchor.minX - Self.gap - size.width
            : right
        return max(Self.margin, min(placed, bounds.width - size.width - Self.margin))
    }

    private func y(in bounds: CGSize) -> CGFloat {
        max(Self.margin, min(presenter.anchor.minY, bounds.height - size.height - Self.margin))
    }
}

private struct TooltipMeasurement: Equatable {
    var generation = -1
    var size = CGSize.zero
}

private struct TooltipSizeKey: PreferenceKey {
    static let defaultValue = TooltipMeasurement()
    static func reduce(value: inout TooltipMeasurement,
                       nextValue: () -> TooltipMeasurement) {
        value = nextValue()
    }
}
