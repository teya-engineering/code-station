import AppKit
import SwiftUI

// MARK: - Anchors

// The places in the sidebar a carried tile can fly from or to. Rows only report them
// while something is being carried or is landing, so a plain scroll costs nothing.
enum SidebarCarryAnchor: Hashable {
    // A project row's own tile, where a tile goes home to.
    case tile(UUID)
    // The empty slot a workspace row shows for the project being carried.
    case slot(UUID)
    // A small tile in a workspace row's roster: workspace, then project.
    case roster(UUID, UUID)
}

struct SidebarCarryAnchors: PreferenceKey {
    static let defaultValue: [SidebarCarryAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [SidebarCarryAnchor: Anchor<CGRect>],
                       nextValue: () -> [SidebarCarryAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    @ViewBuilder
    func sidebarCarryAnchor(_ anchor: SidebarCarryAnchor, active: Bool) -> some View {
        if active {
            anchorPreference(key: SidebarCarryAnchors.self, value: .bounds) { [anchor: $0] }
        } else {
            self
        }
    }
}

// MARK: - Roster

// What a workspace row shows in place of its session count while a project is carried
// or has just landed: its projects as small tiles, and a slot for the one in hand. It
// sits where the count was, so no row changes height and nothing moves under the pointer.
struct SidebarRoster: Equatable {
    struct Member: Equatable, Identifiable {
        let id: UUID
        let name: String
    }

    let workspaceID: UUID
    let members: [Member]
    // The project in hand. A workspace that already holds it rings its tile; one that
    // can take it shows a dashed slot in its colour.
    var carried: Member?
    var holdsCarried = false
    // The pointer is over this row and letting go would add the project.
    var aimed = false
    // The member that has just landed. It pops in and sends out its rings.
    var landed: UUID?
    var landing: Int?
    // A member that has been taken back and is flying home. Its place is kept, empty,
    // until it has gone, so the flight has somewhere to start from.
    var leaving: UUID?
}

struct SidebarRosterView: View {
    let roster: SidebarRoster
    let anchorsActive: Bool

    private static let side: CGFloat = 18
    // Past five, four show and the rest are counted, so the roster never pushes into
    // the name.
    private static let limit = 5

    var body: some View {
        let shown = roster.members.count > Self.limit ? Array(roster.members.prefix(4)) : roster.members
        HStack(spacing: Space.xxs) {
            ForEach(shown) { member in
                tile(member)
            }
            if roster.members.count > shown.count {
                Text("+\(roster.members.count - shown.count)")
                    .font(.mono(Typography.Size.micro, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xxs)
            }
            if let carried = roster.carried, !roster.holdsCarried {
                slot(carried)
            }
        }
        .accessibilityHidden(true)
    }

    private func tile(_ member: SidebarRoster.Member) -> some View {
        let tint = Theme.projectTint(for: member.name)
        let ringed = roster.holdsCarried && roster.carried?.id == member.id
        let landed = roster.landed == member.id
        return ProjectTileView(name: member.name, tint: tint, side: Self.side)
            .overlay(RoundedRectangle(cornerRadius: Self.side * 0.27)
                .stroke(Theme.accent, lineWidth: ringed ? 1.5 : 0))
            .landingRings(landed ? roster.landing : nil, colour: tint.colour, cornerRadius: Self.side * 0.27)
            .opacity(roster.leaving == member.id ? 0 : 1)
            .sidebarCarryAnchor(.roster(roster.workspaceID, member.id), active: anchorsActive)
            .modifier(Landed(active: landed))
    }

    // The slot fills and swells a little while the pointer is over the row, and shows
    // the initial it is waiting for.
    private func slot(_ carried: SidebarRoster.Member) -> some View {
        let tint = Theme.projectTint(for: carried.name)
        let radius = Self.side * 0.27
        return RoundedRectangle(cornerRadius: radius)
            .fill(tint.colour.opacity(roster.aimed ? 0.18 : 0))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(tint.colour.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.3, dash: roster.aimed ? [] : [3, 2])))
            .overlay {
                Text(String(carried.name.prefix(1)).uppercased())
                    .font(.mono(Self.side * 0.42, .semibold))
                    .foregroundStyle(tint.ink)
                    .opacity(roster.aimed ? 0.6 : 0)
            }
            .frame(width: Self.side, height: Self.side)
            .sidebarCarryAnchor(.slot(roster.workspaceID), active: anchorsActive)
            .scaleEffect(roster.aimed ? 1.14 : 1)
            .motion(Motion.control, value: roster.aimed)
    }

    // A tile that has just landed pops into its place.
    private struct Landed: ViewModifier {
        let active: Bool

        func body(content: Content) -> some View {
            if active {
                content.arrives(after: 0, growing: 0.5, animation: Motion.pop)
            } else {
                content
            }
        }
    }
}

// MARK: - Chip

// What a person sees the target do before letting go.
struct SidebarCarryCaption: Equatable {
    enum Kind: Equatable {
        case add
        case refused
        case pair
    }

    let kind: Kind
    let name: String

    var lead: String {
        switch kind {
        case .add: "Add to"
        case .refused: "Already in"
        case .pair: "New workspace with"
        }
    }
}

// The project in hand: its tile and name on a small card. It hangs below and to the
// right of the pointer, so the row being aimed at is never covered. It leans while it
// is only being carried and straightens over a row that would take it, which unfolds
// one line under the name saying what letting go would do.
private struct SidebarCarryChip: View {
    let name: String
    let caption: SidebarCarryCaption?

    static let tile: CGFloat = 26
    static let inset: CGFloat = Space.sm

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let accepts = caption.map { $0.kind != .refused } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                ProjectTileView(name: name, tint: Theme.projectTint(for: name), side: Self.tile)
                Text(name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
            }
            if let caption {
                HStack(spacing: Space.xs) {
                    Image(systemName: caption.kind == .refused ? "nosign" : "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(caption.kind == .refused ? Color.secondary : Theme.onFill)
                        .frame(width: 14, height: 14)
                        .background(caption.kind == .refused ? Theme.field : Theme.accentFill, in: Circle())
                    Text(caption.lead)
                        .foregroundStyle(.secondary)
                    Text(caption.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .font(Typography.caption)
                .padding(.top, Space.xs)
                .padding(.leading, Space.xxs)
                .transition(.opacity)
            }
        }
        .padding(Self.inset)
        .padding(.trailing, Space.sm)
        .frame(maxWidth: 290, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(accepts ? Theme.accent : Theme.border, lineWidth: accepts ? 1.5 : 1))
        .elevation(.floating)
        .rotationEffect(.degrees(caption == nil && !reduceMotion ? -2.5 : 0), anchor: .topLeading)
        .scaleEffect(shown || reduceMotion ? 1 : 0.9, anchor: .topLeading)
        .opacity(shown ? 1 : 0)
        .motion(Motion.control, value: caption)
        .motion(Motion.pop, value: shown)
        .fixedSize()
        .onAppear { shown = true }
    }
}

// MARK: - Layer

// A flight the sidebar asks the carry layer for: the tile of `name`, from the chip or
// from a place in the sidebar, to another place.
struct SidebarCarryFlight: Identifiable, Equatable {
    enum Source: Equatable {
        case chip
        case anchor(SidebarCarryAnchor)
    }

    let id = UUID()
    let name: String
    let from: Source
    let to: SidebarCarryAnchor
    var duration: TimeInterval = Motion.flightDuration
    // Lands where the back tile of a stacked tile sits, up and to the right of `to`,
    // so the tile reads as tucking in behind it.
    var landsBehind = false
}

// The project in hand, as the window-wide layer draws it. The chip lives at the top of
// the window rather than inside the sidebar, so it can hang past the sidebar's edge and
// sit over hints and everything else, the way the thing in your hand should.
@MainActor
@Observable
final class CarryPresenter {
    private(set) var name: String?
    private(set) var caption: SidebarCarryCaption?
    // Where the pointer is in the window, measured from the top. Empty while the pointer
    // is away from the sidebar, which hides the chip.
    private(set) var pointer: CGPoint?

    var isCarrying: Bool { name != nil }

    func carry(_ name: String?, caption: SidebarCarryCaption?) {
        if self.name != name { self.name = name }
        if self.caption != caption { self.caption = caption }
        if name == nil { pointer = nil }
    }

    func move(to point: CGPoint?) {
        if pointer != point { pointer = point }
    }
}

struct CarryHost: View {
    @Environment(CarryPresenter.self) private var presenter

    // The chip's corner sits this far below and to the right of the pointer.
    static let hang = CGSize(width: 12, height: 16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let name = presenter.name, let pointer = presenter.pointer {
                SidebarCarryChip(name: name, caption: presenter.caption)
                    .offset(x: pointer.x + Self.hang.width, y: pointer.y + Self.hang.height)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.leave)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Drawn over the sidebar's list: the tiles in flight. The pointer is followed here, in a
// view of its own, so the rest of the sidebar is not laid out again each time it moves.
struct SidebarCarryLayer: View {
    let carried: String?
    let caption: SidebarCarryCaption?
    let flight: SidebarCarryFlight?
    let anchors: [SidebarCarryAnchor: Anchor<CGRect>]
    let proxy: GeometryProxy
    // The mouse button went up. A drop that landed has already been handled by the row,
    // so this is how a drag let go on nothing, or cancelled, is noticed.
    let onReleased: () -> Void
    let onLanded: (SidebarCarryFlight) -> Void

    @Environment(CarryPresenter.self) private var carry: CarryPresenter?
    @Environment(TooltipPresenter.self) private var tooltips: TooltipPresenter?
    @State private var pointer: CGPoint?
    // Where the chip's tile last was, so a flight can start from it after the chip is gone.
    @State private var chipTile: CGRect?
    @State private var flying: (request: SidebarCarryFlight, path: Flight)?

    private static let hang = CarryHost.hang

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let flying {
                FlightView(flight: flying.path, onLanded: { land(flying.request) }) {
                    ProjectTileView(name: flying.request.name,
                                    tint: Theme.projectTint(for: flying.request.name),
                                    side: flying.path.from.width)
                }
                .id(flying.path.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: carried) { await follow() }
        .onChange(of: carried, initial: true) { _, carried in
            // A hint that comes up under the pointer mid-drag would only get in the way.
            tooltips?.hold(carried != nil)
            carry?.carry(carried, caption: caption)
        }
        .onChange(of: caption) { _, caption in carry?.carry(carried, caption: caption) }
        .onChange(of: flight) { _, request in start(request) }
        .onDisappear {
            tooltips?.hold(false)
            carry?.carry(nil, caption: nil)
        }
    }

    // Reads the pointer from the window server about once a frame while a project is
    // carried. Drop targets only hear about the pointer while it is over them, and the
    // chip has to follow it across the gaps between rows too.
    private func follow() async {
        guard carried != nil else { return }
        while !Task.isCancelled {
            if let window = NSApp.keyWindow, let content = window.contentView {
                let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                let global = CGPoint(x: point.x, y: content.bounds.height - point.y)
                let origin = proxy.frame(in: .global).origin
                let local = CGPoint(x: global.x - origin.x, y: global.y - origin.y)
                let near = proxy.frame(in: .local).insetBy(dx: -40, dy: -40).contains(local)
                carry?.move(to: near ? global : nil)
                if local != pointer {
                    pointer = local
                    chipTile = CGRect(x: local.x + Self.hang.width + SidebarCarryChip.inset,
                                      y: local.y + Self.hang.height + SidebarCarryChip.inset,
                                      width: SidebarCarryChip.tile, height: SidebarCarryChip.tile)
                }
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                onReleased()
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func rect(_ anchor: SidebarCarryAnchor) -> CGRect? {
        anchors[anchor].map { proxy[$0] }
    }

    private func start(_ request: SidebarCarryFlight?) {
        guard let request else { return }
        let from: CGRect? = switch request.from {
        case .chip: chipTile
        case .anchor(let anchor): rect(anchor)
        }
        guard let from, var to = rect(request.to) else {
            // Nowhere to fly from or to, such as a row scrolled out of the list: the
            // flight is skipped and the landing happens in place.
            onLanded(request)
            return
        }
        if request.landsBehind {
            to = to.offsetBy(dx: to.width * ProjectTileBack.shift, dy: -to.height * ProjectTileBack.shift)
        }
        flying = (request, Flight(from: from, to: to, duration: request.duration))
    }

    private func land(_ request: SidebarCarryFlight) {
        if flying?.request.id == request.id { flying = nil }
        onLanded(request)
    }
}

// MARK: - Sequence

struct SidebarLanding: Equatable {
    enum Phase: Equatable {
        case flying
        case landed
        // Taken back from the receipt, and flying home.
        case leaving
    }

    let workspaceID: UUID
    let projectID: UUID
    // The workspace as it stood before the add, which is what an undo puts back.
    let before: ProjectWorkspace
    var phase: Phase
    // Tells one landing from the next, so a late timer from an earlier one leaves a new
    // one alone.
    let token: Int
}

struct SidebarPairing: Equatable {
    // A beat for the pile to be seen before the sheet covers the sidebar.
    static let sheetDelay: Duration = .milliseconds(240)

    let targetID: UUID
    let projectID: UUID
    var stacked: Bool
}

// A project carried in the sidebar, from the drag to the row settling again.
//
// Dropped on a workspace: `join` adds it and sends its tile flying to the row, the
// landing makes the row blink, a beat later the receipt says what changed, and a moment
// after the receipt closes the row puts its roster away. Undo in the receipt flies the
// tile home instead.
//
// Dropped on another project: `pair` tucks its tile behind the target, and a beat after
// it lands the sidebar is asked for a workspace of the two.
//
// A landing and a pairing can be under way at the same time, and there is one flight
// between them: a drop made during a flight takes the flight over.
@MainActor
@Observable
final class SidebarCarry {
    // What the carry reaches outside itself: the data it changes, and the parts of the
    // sidebar that answer it.
    struct Surroundings {
        let store: ProjectStore
        let dialogs: DialogPresenter
        let note: TransientNote
        let openWorkspace: (ProjectWorkspace) -> Void
        // The projects to start the New workspace sheet with, and a name for the pair.
        let proposeWorkspace: ([UUID], String) -> Void
    }

    var drag = SidebarDrag()
    // A project dropped on a workspace, from its flight into the row until the row puts
    // its roster away again.
    private(set) var landing: SidebarLanding?
    private(set) var flight: SidebarCarryFlight?
    // A project dropped on another project, tucked behind it while the New workspace
    // sheet asks for the rest.
    private(set) var pairing: SidebarPairing?

    @ObservationIgnored private var landings = 0
    @ObservationIgnored private let sleep: (Duration) async -> Void

    init(sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func carriedProject(in store: ProjectStore) -> Project? {
        guard let id = drag.itemID, let project = store.project(id), project.kind == .project
        else { return nil }
        return project
    }

    // The mouse went up. A drop a row took has already cleared the drag; one still in
    // hand a moment later was let go on nothing or cancelled, and its tile goes home
    // rather than vanishing. The moment is there because the button reads as up a
    // little before the row hears of the drop.
    func dragReleased(in around: Surroundings) {
        Task { @MainActor in
            await sleep(.milliseconds(150))
            guard let project = carriedProject(in: around.store) else { return }
            drag = SidebarDrag()
            flight = SidebarCarryFlight(name: project.name, from: .chip, to: .tile(project.id),
                                        duration: Motion.flightHomeDuration)
        }
    }

    func flightLanded(_ landed: SidebarCarryFlight, in around: Surroundings) {
        if flight?.id == landed.id { flight = nil }
        if landed.landsBehind, let pair = pairing, !pair.stacked, landed.to == .tile(pair.targetID) {
            pairLanded(pair, in: around)
            return
        }
        guard let current = landing else { return }
        switch (landed.to, current.phase) {
        case (.slot(let workspaceID), .flying) where workspaceID == current.workspaceID:
            landing?.phase = .landed
            around.store.navigation.sidebarHighlight = workspaceID
            showReceipt(for: current, in: around)
        case (.tile(let projectID), .leaving) where projectID == current.projectID:
            landing = nil
        default:
            break
        }
    }

    // MARK: Onto a workspace

    // The add happens at once, so the workspace page and its count already show it. The
    // row's roster still shows the slot while the tile flies in, and fills it on landing.
    func join(_ id: UUID, _ workspace: ProjectWorkspace, in around: Surroundings) {
        guard let before = WorkspaceAddition.add(id, to: workspace.id, store: around.store),
              let project = around.store.project(id) else { return }
        landings += 1
        landing = SidebarLanding(workspaceID: workspace.id, projectID: id, before: before,
                                 phase: .flying, token: landings)
        flight = SidebarCarryFlight(name: project.name, from: .chip, to: .slot(workspace.id))
    }

    // An add made away from the sidebar has no flight in: the tile lands in the row at
    // once, and everything after that is the same as a drop.
    func landInPlace(_ added: WorkspaceAddition.Added, in around: Surroundings) {
        landings += 1
        let landed = SidebarLanding(workspaceID: added.before.id, projectID: added.projectID,
                                    before: added.before, phase: .landed, token: landings)
        landing = landed
        around.store.navigation.sidebarHighlight = added.before.id
        showReceipt(for: landed, in: around)
    }

    private func showReceipt(for landed: SidebarLanding, in around: Surroundings) {
        Task { @MainActor in
            await sleep(WorkspaceAddition.receiptDelay)
            guard landing?.token == landed.token,
                  let workspace = around.store.workspace(landed.workspaceID) else { return }
            let isOpen = around.store.selection == .workspace(workspace.id)
            guard let receipt = WorkspaceAddition.receipt(
                for: landed.projectID, before: landed.before, store: around.store,
                onUndo: { self.undoLanding(landed, in: around) },
                onOpen: isOpen ? nil : { around.openWorkspace(workspace) },
                onClose: { self.putRosterAway(landed) }) else {
                landing = nil
                return
            }
            around.dialogs.show(receipt)
        }
    }

    // The roster stays a moment after the receipt closes, so the person sees the project
    // in its new place before the row goes back to its count.
    private func putRosterAway(_ landed: SidebarLanding) {
        Task { @MainActor in
            await sleep(.milliseconds(1_300))
            if landing?.token == landed.token { landing = nil }
        }
    }

    private func undoLanding(_ landed: SidebarLanding, in around: Surroundings) {
        let name = around.store.project(landed.projectID)?.name ?? "The project"
        let workspace = around.store.workspace(landed.workspaceID)?.name ?? "the workspace"
        around.note.show("Removed \(name) from \(workspace)", icon: "arrow.uturn.backward")
        guard landing?.token == landed.token else { return }
        landing?.phase = .leaving
        flight = SidebarCarryFlight(name: name,
                                    from: .anchor(.roster(landed.workspaceID, landed.projectID)),
                                    to: .tile(landed.projectID),
                                    duration: Motion.flightHomeDuration)
    }

    // MARK: Onto another project

    // The project dropped on leads, since it is the one the person aimed for. The
    // dropped tile flies in behind it first, so the row shows the two as a pile before
    // the sheet asks to make that pile a workspace.
    func pair(_ id: UUID, with project: Project, in around: Surroundings) {
        guard let dropped = around.store.project(id) else { return }
        pairing = SidebarPairing(targetID: project.id, projectID: id, stacked: false)
        flight = SidebarCarryFlight(name: dropped.name, from: .chip, to: .tile(project.id),
                                    landsBehind: true)
    }

    private func pairLanded(_ pair: SidebarPairing, in around: Surroundings) {
        pairing?.stacked = true
        Task { @MainActor in
            await sleep(SidebarPairing.sheetDelay)
            guard pairing == SidebarPairing(targetID: pair.targetID, projectID: pair.projectID, stacked: true),
                  let target = around.store.project(pair.targetID),
                  let dropped = around.store.project(pair.projectID) else {
                pairing = nil
                return
            }
            around.proposeWorkspace([target.id, dropped.id], "\(target.name) + \(dropped.name)")
        }
    }

    // The New workspace sheet closed, with a workspace made or not. Either way the pile
    // comes apart.
    func endPairing() {
        pairing = nil
    }
}
