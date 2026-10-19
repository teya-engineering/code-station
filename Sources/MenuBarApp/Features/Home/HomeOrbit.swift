import SwiftUI
import CodeStationCore

// Where every shape on the orbit map sits. Worked out from the map and the width alone, so
// it can be checked without drawing anything.
//
// Projects take a left and a right column so their sessions always have room to reach
// outward, away from the hub. The map is only as tall as its busiest column, and a column
// grows the map rather than squeezing its rows, so sessions are never laid over each other.
//
// The ring in the middle is split the way the columns are: the right half holds the right
// column's sessions from the top down, and the left half the left column's. Each project's
// wire leaves the ring from the middle of its own share of it, so the ring and the wires
// always agree.
struct OrbitLayout {
    struct Node: Identifiable {
        let group: HomeWorkMap.Group
        let center: CGPoint
        let left: Bool
        // The project's share of the ring, in fractions of a turn clockwise from the top.
        var segment: ClosedRange<CGFloat> = 0...0
        var id: UUID { group.id }
    }

    // One session's arc on the ring. Every session has one, including those past the
    // ones shown as pills.
    struct Arc: Identifiable {
        let live: HomeLive
        let start: CGFloat
        let end: CGFloat
        let left: Bool
        // How many arcs come before this one on its side of the ring.
        let step: Int
        var id: UUID { live.id }
    }

    struct Pill: Identifiable {
        let live: HomeLive
        let frame: CGRect
        var left = false
        var id: UUID { live.id }
    }

    struct More: Identifiable {
        let group: HomeWorkMap.Group
        let count: Int
        let frame: CGRect
        var left = false
        var id: UUID { group.id }
    }

    struct Wire: Identifiable {
        enum Kind { case running, attention, quiet }
        let id: String
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
        let kind: Kind
        // From the hub to a project, drawn a little heavier than a project to a session.
        let trunk: Bool
        // What the wire belongs to, so it can stay lit with them.
        var group: UUID?
        var session: UUID?
        // Its place among the wires of its kind, for the order they grow in.
        var order = 0

        init(id: String, start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint,
             kind: Kind, trunk: Bool, group: UUID? = nil, session: UUID? = nil, order: Int = 0) {
            self.id = id
            self.start = start
            self.control1 = control1
            self.control2 = control2
            self.end = end
            self.kind = kind
            self.trunk = trunk
            self.group = group
            self.session = session
            self.order = order
        }

        init(id: String, start: CGPoint, end: CGPoint, kind: Kind, trunk: Bool,
             group: UUID? = nil, session: UUID? = nil, order: Int = 0) {
            let connector = MapConnector(start: start, end: end)
            self.init(id: id, start: start, control1: connector.control1, control2: connector.control2,
                      end: end, kind: kind, trunk: trunk, group: group, session: session, order: order)
        }

        var connector: MapConnector {
            MapConnector(start: start, control1: control1, control2: control2, end: end)
        }
    }

    static let ringRadius: CGFloat = 76
    static let ringWidth: CGFloat = 11
    static let projectRingRadius: CGFloat = 91
    static let projectRingWidth: CGFloat = 3
    static let orbitRadius: CGFloat = 57
    static let hubSide: CGFloat = 2 * projectRingRadius + 6
    // The space left at each end of an arc, as a fraction of a turn.
    static let arcGap: CGFloat = 0.022 / (2 * .pi)
    static let tileSide: CGFloat = 40
    static let pillHeight: CGFloat = 32
    static let tallPillHeight: CGFloat = 48
    static let pillGap: CGFloat = 8
    static let maxProjects = 10
    static let maxSessions = 20
    // Past this many sessions each project shows two pills rather than three, so a busy
    // day still fits on a screen. The ring always shows every session.
    static let roomyDay = 12
    // A narrower map leaves the session pills too short to read a title in.
    static let minWidth: CGFloat = 860
    // A tile sits this far above the middle of its row, so the name under it stays inside
    // the row.
    static let tileLift: CGFloat = 8
    private static let margin: CGFloat = 22
    // Room for the ring with space around it, and for a medium day's column of pills, so
    // the map keeps one height on most days.
    static let minHeight: CGFloat = hubSide + 2 * margin + 76
    // Room above the map for the phone pills and the line that runs from them to the ring.
    static let phoneBand: CGFloat = 76

    // How much height a project takes when it has a single session: the tile, its halo and
    // the name under it.
    private static let nodeExtent: CGFloat = 84
    private static let rowGap: CGFloat = 22
    private static let pillReach: CGFloat = 50
    // A project's wire leaves just outside the project ring.
    private static let wireRadius: CGFloat = projectRingRadius + 6
    // The name under a tile stops short of the pills beside it.
    static let nameWidth: CGFloat = 2 * pillReach - 8

    let size: CGSize
    let hub: CGPoint
    // How far the map is pushed down to make room for the phone pills.
    let phoneBand: CGFloat
    let pillWidth: CGFloat
    let shownPerProject: Int
    // The most arcs on either side of the ring, which is how long the ring takes to draw.
    private(set) var steps = 0
    private(set) var nodes: [Node] = []
    private(set) var arcs: [Arc] = []
    private(set) var pills: [Pill] = []
    private(set) var more: [More] = []
    private(set) var wires: [Wire] = []

    // Everything that moves when the map changes, so the move can be animated as one.
    var motionKey: [CGRect] {
        nodes.map { CGRect(origin: $0.center, size: .zero) } + pills.map(\.frame) + more.map(\.frame)
            + arcs.map { CGRect(x: $0.start, y: $0.end, width: 0, height: 0) }
    }

    init(map: HomeWorkMap, width: CGFloat, phoneBand: CGFloat = 0) {
        self.phoneBand = phoneBand
        let groups = map.groups
        let shownPerProject = map.active.count > Self.roomyDay ? 2 : 3
        self.shownPerProject = shownPerProject
        let leftCount = (groups.count + 1) / 2
        let columns = [(Array(groups.prefix(leftCount)), true),
                       (Array(groups.dropFirst(leftCount)), false)]

        func stack(_ group: HomeWorkMap.Group) -> (shown: [HomeLive], hidden: Int, height: CGFloat) {
            let shown = Array(group.sessions.prefix(shownPerProject))
            let hidden = group.sessions.count - shown.count
            let heights = shown.map(Self.height(of:)) + (hidden > 0 ? [Self.pillHeight] : [])
            return (shown, hidden, heights.reduce(0, +) + Self.pillGap * CGFloat(heights.count - 1))
        }
        func extent(_ group: HomeWorkMap.Group) -> CGFloat { max(Self.nodeExtent, stack(group).height) }

        let columnHeights = columns.map { column, _ in
            column.map(extent).reduce(0, +) + Self.rowGap * CGFloat(max(column.count - 1, 0))
        }
        let mapHeight = max(Self.minHeight, (columnHeights.max() ?? 0) + 2 * Self.margin)
        size = CGSize(width: width, height: mapHeight + phoneBand)
        let centerX = width / 2
        let centerY = phoneBand + mapHeight / 2
        hub = CGPoint(x: centerX, y: centerY)

        let reach = min(240, max(200, width * 0.19))
        pillWidth = min(300, centerX - reach - Self.pillReach - 10)
        let tileEdge = Self.tileSide / 2 + 7
        // With a single column its side of the ring is the whole ring.
        let share: CGFloat = columns[1].0.isEmpty ? 1 : 0.5

        for (index, (column, left)) in columns.enumerated() {
            let total = column.map(\.sessions.count).reduce(0, +)
            let unit = share / CGFloat(max(total, 1))
            var done = 0
            var top = centerY - columnHeights[index] / 2
            for group in column {
                let rowHeight = extent(group)
                let y = top + rowHeight / 2
                // Rows further from the middle bend in towards the hub, which is what turns
                // two columns into an orbit.
                let bend = min(abs(y - centerY), 170) * 0.3
                let x = left ? centerX - reach + bend : centerX + reach - bend
                let tile = CGPoint(x: x, y: y - Self.tileLift)

                // The right half fills clockwise from the top and the left half the other
                // way, so both read from the top down, as the columns do.
                let count = group.sessions.count
                let segment = left
                    ? (1 - CGFloat(done + count) * unit)...(1 - CGFloat(done) * unit)
                    : (CGFloat(done) * unit)...(CGFloat(done + count) * unit)
                for (slot, live) in group.sessions.enumerated() {
                    let step = done + slot
                    let start = left ? 1 - CGFloat(step + 1) * unit : CGFloat(step) * unit
                    arcs.append(Arc(live: live, start: start, end: start + unit, left: left, step: step))
                }
                done += count
                nodes.append(Node(group: group, center: tile, left: left, segment: segment))

                // Out of the middle of the project's segment, heading away from the ring,
                // then round to arrive level at the tile. A project that holds the whole
                // ring has no middle to speak of, so its wire leaves facing its tile.
                let angle = segment.upperBound - segment.lowerBound >= 1
                    ? atan2(tile.y - centerY, tile.x - centerX)
                    : (segment.lowerBound + segment.upperBound) * .pi - .pi / 2
                let outward = CGPoint(x: cos(angle), y: sin(angle))
                let start = CGPoint(x: centerX + outward.x * Self.wireRadius,
                                    y: centerY + outward.y * Self.wireRadius)
                let end = CGPoint(x: x + (left ? 1 : -1) * tileEdge, y: tile.y)
                wires.append(Wire(id: "hub:\(group.id)", start: start,
                                  control1: CGPoint(x: start.x + outward.x * 46, y: start.y + outward.y * 46),
                                  control2: CGPoint(x: end.x + (left ? 56 : -56), y: end.y),
                                  end: end, kind: Self.kind(of: group.sessions), trunk: true,
                                  group: group.id, order: nodes.count - 1))

                let (shown, hidden, stackHeight) = stack(group)
                let pillX = left ? x - Self.pillReach - pillWidth : x + Self.pillReach
                let branch = CGPoint(x: x + (left ? -1 : 1) * tileEdge, y: tile.y)
                var pillY = y - stackHeight / 2
                for live in shown {
                    let frame = CGRect(x: pillX, y: pillY, width: pillWidth, height: Self.height(of: live))
                    pills.append(Pill(live: live, frame: frame, left: left))
                    wires.append(Wire(id: "session:\(live.id)", start: branch,
                                      end: CGPoint(x: left ? frame.maxX : frame.minX, y: frame.midY),
                                      kind: Self.kind(of: [live]), trunk: false,
                                      group: group.id, session: live.id, order: pills.count - 1))
                    pillY = frame.maxY + Self.pillGap
                }
                if hidden > 0 {
                    let frame = CGRect(x: pillX, y: pillY, width: pillWidth, height: Self.pillHeight)
                    more.append(More(group: group, count: hidden, frame: frame, left: left))
                    wires.append(Wire(id: "more:\(group.id)", start: branch,
                                      end: CGPoint(x: left ? frame.maxX : frame.minX, y: frame.midY),
                                      kind: .quiet, trunk: false, group: group.id, order: pills.count))
                }
                top += rowHeight + Self.rowGap
            }
            steps = max(steps, total)
        }
    }

    // Where a phone's line meets the ring: the top of the project ring, just outside it.
    var ringTop: CGPoint {
        CGPoint(x: hub.x, y: hub.y - Self.projectRingRadius - 5)
    }

    // A session that needs you is the one tall shape on the map, so it is found first.
    static func height(of live: HomeLive) -> CGFloat {
        live.needsAttention ? tallPillHeight : pillHeight
    }

    // A wire takes the state of the busiest thing it leads to.
    static func kind(of sessions: [HomeLive]) -> Wire.Kind {
        sessions.contains(where: \.needsAttention) ? .attention
            : sessions.contains(where: { $0.tone == .running }) ? .running : .quiet
    }

    // Where a session's card opens: beside its pill, reaching in towards the middle of the
    // map, under the pill when it fits and above it when it would run off the bottom. A
    // session only on the ring opens under the ring. The card may hang over the card's
    // own padding and heading, but never past them.
    func cardCenter(for id: UUID, size card: CGSize) -> CGPoint {
        let half = card.width / 2
        let lowest = size.height + 14
        let highest: CGFloat = -30
        let x: CGFloat
        let top: CGFloat
        if let pill = pills.first(where: { $0.id == id }) {
            x = pill.left ? pill.frame.minX + half : pill.frame.maxX - half
            let below = pill.frame.maxY + 6 + card.height <= lowest
            top = below ? pill.frame.maxY + 6 : pill.frame.minY - 6 - card.height
        } else {
            x = hub.x
            top = hub.y + Self.projectRingRadius + 10
        }
        return CGPoint(x: min(max(x, half + 10), size.width - half - 10),
                       y: max(min(top, lowest - card.height), highest) + card.height / 2)
    }

    // The session arc under a point in the hub, where the hub is a square of `hubSide`. It
    // goes by the point's angle and distance from the middle, since every arc's view
    // covers the whole square and a hover over that square would light them all.
    func arc(at point: CGPoint) -> Arc? {
        let dx = point.x - Self.hubSide / 2
        let dy = point.y - Self.hubSide / 2
        let reach = (Self.ringWidth + 6) / 2
        guard abs(hypot(dx, dy) - Self.ringRadius) <= reach else { return nil }
        // A fraction of a turn, clockwise from the top, as the arcs are laid out.
        var turn = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if turn < 0 { turn += 1 }
        return arcs.first { $0.start <= turn && turn < $0.end }
    }
}

// When each part of the orbit arrives as it builds itself up, in seconds from the start:
// the ring from the top down both sides, then the wires out to each project and its tile,
// then the wires on to each session and its pill, and only then the moving dashes.
struct OrbitOpening {
    let ringDone: Double
    private let pillCount: Int

    init(layout: OrbitLayout) {
        ringDone = Double(layout.steps) * 0.055 + 0.45
        pillCount = layout.pills.count
    }

    func arc(_ step: Int) -> Double { Double(step) * 0.055 }
    func projectRing(_ index: Int) -> Double { max(0, ringDone - 0.3) + Double(index) * 0.04 }
    func tile(_ index: Int) -> Double { ringDone + 0.38 + Double(index) * 0.07 }
    func pill(_ index: Int) -> Double { leaves + 0.2 + Double(index) * 0.045 }
    var more: Double { leaves + 0.4 }
    var flow: Double { pill(pillCount) + 0.3 }

    func wire(_ wire: OrbitLayout.Wire) -> Double {
        wire.trunk ? ringDone + Double(wire.order) * 0.07 : leaves + Double(wire.order) * 0.045
    }

    private var leaves: Double { ringDone + 0.6 }

    static let draw = Animation.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.6)
    static let slide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)
    static let pop = Animation.spring(response: 0.5, dampingFraction: 0.6)
}

// What the pointer is resting on. That session or project stays lit, with everything that
// leads to it, and the rest of the map dims.
enum OrbitSpotlight: Equatable {
    case session(UUID, group: UUID)
    case project(UUID)

    func lights(group: UUID?, session: UUID?) -> Bool {
        switch self {
        case .project(let id):
            return group == id
        case .session(let id, let owner):
            if let session { return session == id }
            return group == owner
        }
    }

    static func opacity(_ spotlight: OrbitSpotlight?, group: UUID?, session: UUID? = nil) -> Double {
        spotlight?.lights(group: group, session: session) == false ? 0.2 : 1
    }
}

// The work map drawn around a ring with one arc for every session. Projects sit on either
// side with their sessions beside them, and a session that needs you grows taller and
// turns amber. Clicking a session, on its pill or its arc, opens its card, where a
// request can be answered without leaving Home.
struct OrbitMap: View {
    let map: HomeWorkMap
    let width: CGFloat
    let hasChanges: (HomeLive) -> Bool
    let workTime: (HomeLive) -> TimeInterval
    let open: (HomeLive, SessionDestination) -> Void
    let answer: (HomeLive, PermissionAnswer) -> Void
    let reveal: (HomeWorkMap.Group) -> Void
    let onOpened: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: UUID?
    @State private var cardHeight: CGFloat = 240
    @State private var pointed: OrbitSpotlight?
    @State private var beaconFrame: CGRect?
    @State private var ripples = 0
    // False only until a map that opens has appeared. Everything on the map reads it,
    // each part with its own delay, so the opening is one change played in order.
    @State private var built: Bool

    init(map: HomeWorkMap, width: CGFloat, hasChanges: @escaping (HomeLive) -> Bool,
         workTime: @escaping (HomeLive) -> TimeInterval,
         open: @escaping (HomeLive, SessionDestination) -> Void,
         answer: @escaping (HomeLive, PermissionAnswer) -> Void,
         reveal: @escaping (HomeWorkMap.Group) -> Void,
         opening: Bool, onOpened: @escaping () -> Void) {
        self.map = map
        self.width = width
        self.hasChanges = hasChanges
        self.workTime = workTime
        self.open = open
        self.answer = answer
        self.reveal = reveal
        self.onOpened = onOpened
        _built = State(initialValue: !opening)
    }

    var body: some View {
        let phone = phoneLink
        let layout = OrbitLayout(map: map, width: width, phoneBand: phone == nil ? 0 : OrbitLayout.phoneBand)
        let opening = OrbitOpening(layout: layout)
        let reach = OrbitPhoneReach(link: phone, map: map)
        // Pointing at a project in the sidebar lights it here too.
        let spotlight = pointed ?? store.navigation.pointedSidebarItem.map(OrbitSpotlight.project)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selected = nil }

            OrbitWires(wires: layout.wires, built: built, opening: opening, spotlight: spotlight,
                       phoneLit: reach.wires)

            if let phone, let beaconFrame {
                OrbitPhoneSignal(link: phone.link, start: CGPoint(x: beaconFrame.midX, y: beaconFrame.maxY + 2),
                                 end: layout.ringTop)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .transition(.opacity)
            }

            OrbitPhoneRipple(trigger: ripples)
                .position(layout.hub)

            OrbitRing(layout: layout, map: map, built: built, opening: opening, spotlight: spotlight,
                      select: { toggle($0) }, point: { point($0, at: $1) })
                .position(layout.hub)

            ForEach(Array(layout.nodes.enumerated()), id: \.element.id) { index, node in
                let group = node.group
                OrbitProjectTile(group: group, built: built,
                                 entrance: step(opening.tile(index), OrbitOpening.pop)) {
                    reveal(group)
                } point: { point(.project(group.id), at: $0) }
                    .position(node.center)
                // Long names wrap rather than cut off, and spill a little into the gap
                // between rows.
                let name = OrbitTileName(name: group.identity.containerName, width: OrbitLayout.nameWidth,
                                         lines: 2)
                name
                    .opacity(built ? 1 : 0)
                    .animation(step(opening.tile(index), OrbitOpening.slide), value: built)
                    .position(name.center(under: node.center))
                    .opacity(OrbitSpotlight.opacity(spotlight, group: group.id))
            }

            ForEach(Array(layout.pills.enumerated()), id: \.element.id) { index, pill in
                let live = pill.live
                OrbitSessionPill(live: live, selected: selected == pill.id, left: pill.left, built: built,
                                 onPhone: reach.sessions.contains(live.id),
                                 entrance: step(opening.pill(index), OrbitOpening.slide)) {
                    toggle(live.id)
                } point: { point(.session(live.id, group: live.containerID), at: $0) }
                    .frame(width: pill.frame.width, height: pill.frame.height)
                    .position(x: pill.frame.midX, y: pill.frame.midY)
                    .opacity(OrbitSpotlight.opacity(spotlight, group: live.containerID, session: live.id))
            }

            ForEach(layout.more) { more in
                OrbitMoreChip(more: more) { reveal(more.group) }
                    .opacity(built ? 1 : 0)
                    .offset(x: built ? 0 : (more.left ? 14 : -14))
                    .animation(step(opening.more, OrbitOpening.slide), value: built)
                    .frame(width: more.frame.width, height: more.frame.height)
                    .position(x: more.frame.midX, y: more.frame.midY)
                    .opacity(OrbitSpotlight.opacity(spotlight, group: more.group.id))
            }

            if let phone {
                beacon(phone, layout: layout)
            }

            if let selected, let live = map.active.first(where: { $0.id == selected }) {
                card(for: live, in: layout)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .coordinateSpace(.named(Self.space))
        .motion(HomeWorkMapView.reflow, value: layout.motionKey)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: spotlight)
        .animation(reduceMotion ? nil : Self.drop, value: phone)
        .onChange(of: phone?.connected == true) { _, now in
            if now && !reduceMotion { ripples += 1 }
        }
        .onExitCommand { selected = nil }
        .onAppear {
            built = true
            onOpened()
        }
    }

    nonisolated private static let space = "orbit"
    private static let drop = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55)

    private var phoneLink: OrbitPhoneLink? {
        guard let share = mobileAccess.share else { return nil }
        let open = mobileAccess.openSession
        return OrbitPhoneLink(connected: share.isConnected, openSession: open,
                              openTitle: open.flatMap { store.session($0)?.title })
    }

    // The pill for the code that is out, above the ring. The line from it always goes into
    // the top of the ring; running one straight to a session would cross the pills between.
    private func beacon(_ phone: OrbitPhoneLink, layout: OrbitLayout) -> some View {
        // The second line gives way first when the pill would run past the map.
        let reachWidth = min(280, max(80, layout.size.width - 140))
        return OrbitPhoneBeacon(link: phone, reachWidth: reachWidth) {
            MobilePairing.open(dialogs: dialogs)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            beaconFrame = $0
        }
        .frame(width: layout.size.width, height: OrbitPhoneBeacon.height)
        .position(x: layout.hub.x, y: OrbitPhoneBeacon.height / 2 + 2)
        .transition(.asymmetric(insertion: .offset(y: -14).combined(with: .opacity),
                                removal: .offset(y: -12).combined(with: .opacity)))
    }

    // A part of the opening, or nothing when motion is reduced and the map simply appears.
    private func step(_ delay: Double, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation.delay(delay)
    }

    private func toggle(_ id: UUID) {
        selected = selected == id ? nil : id
    }

    // A pointer leaving one shape can land on the next before the first one hears about
    // it, so leaving only clears what that shape set.
    private func point(_ spotlight: OrbitSpotlight, at hovering: Bool) {
        if hovering {
            pointed = spotlight
        } else if pointed == spotlight {
            pointed = nil
        }
    }

    private func card(for live: HomeLive, in layout: OrbitLayout) -> some View {
        let close = { selected = nil }
        return OrbitSessionCard(
            live: live,
            hasChanges: hasChanges(live),
            workTime: workTime(live),
            open: { destination in
                close()
                open(live, destination)
            },
            answer: { given in
                close()
                answer(live, given)
            },
            reveal: {
                close()
                if let group = map.groups.first(where: { $0.id == live.containerID }) { reveal(group) }
            },
            close: close)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            .position(layout.cardCenter(for: live.id,
                                        size: CGSize(width: OrbitSessionCard.width, height: cardHeight)))
            .zIndex(2)
            .transition(.opacity)
    }
}

private struct OrbitTileName: View {
    let name: String
    let width: CGFloat
    var lines = 1

    // From the middle of a tile to the top of the name under it.
    static let gap: CGFloat = OrbitLayout.tileSide / 2 + 10
    private static let lineHeight: CGFloat = 14

    // Where to put the name's middle so its first line sits the same distance under the tile
    // whatever the number of lines.
    func center(under tile: CGPoint) -> CGPoint {
        CGPoint(x: tile.x, y: tile.y + Self.gap + CGFloat(lines) * Self.lineHeight / 2)
    }

    var body: some View {
        Text(name)
            .font(.system(size: 11.5, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .frame(width: width, height: CGFloat(lines) * Self.lineHeight, alignment: .top)
    }
}

// The sessions a project has past the ones the orbit shows. Clicking it opens the project
// in the sidebar, where every session is listed.
private struct OrbitMoreChip: View {
    let more: OrbitLayout.More
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let name = more.group.identity.containerName
        Button(action: action) {
            Text("+\(more.count) more in \(name)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: OrbitLayout.pillHeight / 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint("Shows \(name) in the sidebar")
    }
}


// The lines from the ring to each project and on to its sessions. A line flows while what
// it leads to is running, and stands still otherwise, so motion on the map always means
// work is happening. The flow is played by Core Animation, so a map full of running work
// costs nothing between frames.
private struct OrbitWires: View {
    let wires: [OrbitLayout.Wire]
    var built = true
    // When each wire grows, for a map that builds itself up.
    var opening: OrbitOpening?
    var spotlight: OrbitSpotlight?
    // The wires a connected phone reaches, drawn green over the rest.
    var phoneLit: Set<String> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reached = wires.filter { phoneLit.contains($0.id) }
        let flowing = reduceMotion ? [] : wires.filter { $0.kind == .running && !phoneLit.contains($0.id) }
        let lit = flowing.filter { OrbitSpotlight.opacity(spotlight, group: $0.group, session: $0.session) == 1 }
        let dim = flowing.filter { OrbitSpotlight.opacity(spotlight, group: $0.group, session: $0.session) < 1 }
        ZStack {
            ForEach(wires) { wire in
                wire.connector
                    .trim(from: 0, to: built ? 1 : 0)
                    .stroke(Self.colour(wire.kind), style: Self.style(wire))
                    .animation(reduceMotion ? nil : OrbitOpening.draw.speed(1.2).delay(opening?.wire(wire) ?? 0),
                               value: built)
                    .opacity(OrbitSpotlight.opacity(spotlight, group: wire.group, session: wire.session))
            }
            ForEach(reached) { wire in
                wire.connector
                    .trim(from: 0, to: built ? 1 : 0)
                    .stroke(Theme.dotOn, style: StrokeStyle(lineWidth: Self.width(wire) + 0.6, lineCap: .round))
                    .transition(.opacity)
            }
            if !reduceMotion && !reached.isEmpty {
                FlowingWires(paths: [2.6: Self.path(reached)], colour: Theme.dotOn, dash: [5, 4], period: 0.8)
                    .opacity(built ? 1 : 0)
                    .transition(.opacity)
            }
            Group {
                if !lit.isEmpty {
                    FlowingWires(paths: Self.paths(lit), colour: Theme.dotOn)
                }
                if !dim.isEmpty {
                    FlowingWires(paths: Self.paths(dim), colour: Theme.dotOn)
                        .opacity(0.2)
                }
            }
            .opacity(built ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(opening?.flow ?? 0), value: built)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // One path for each line width, since a layer strokes every line it holds the same. The
    // moving dashes are a little heavier than the line they run along.
    static func paths(_ wires: [OrbitLayout.Wire]) -> [CGFloat: CGPath] {
        Dictionary(grouping: wires, by: { width($0) + 0.6 }).mapValues(path)
    }

    static func path(_ wires: [OrbitLayout.Wire]) -> CGPath {
        let path = CGMutablePath()
        for wire in wires {
            path.addPath(wire.connector.path(in: .zero).cgPath)
        }
        return path
    }

    static func colour(_ kind: OrbitLayout.Wire.Kind) -> Color {
        switch kind {
        case .attention: Theme.attention.opacity(0.7)
        case .running: Theme.dotOn.opacity(0.38)
        case .quiet: Theme.accent.opacity(0.22)
        }
    }

    static func width(_ wire: OrbitLayout.Wire) -> CGFloat { wire.trunk ? 1.6 : 1.2 }

    static func style(_ wire: OrbitLayout.Wire) -> StrokeStyle {
        let width = width(wire)
        return switch wire.kind {
        case .attention: StrokeStyle(lineWidth: width)
        case .running: StrokeStyle(lineWidth: width, lineCap: .round)
        case .quiet: StrokeStyle(lineWidth: width, dash: [2, 4])
        }
    }
}

struct FlowingWires: NSViewRepresentable {
    let paths: [CGFloat: CGPath]
    let colour: Color
    var dash = FlowingWiresView.wireDash
    var period = FlowingWiresView.wirePeriod

    func makeNSView(context: Context) -> FlowingWiresView {
        FlowingWiresView(dash: dash, period: period)
    }

    func updateNSView(_ view: FlowingWiresView, context: Context) {
        view.update(paths: paths, colour: colour.resolve(in: context.environment).cgColor)
    }
}

final class FlowingWiresView: LoopLayerView {
    static let wireDash: [CGFloat] = [2, 10]
    static let wirePeriod: TimeInterval = 1.3

    private let dash: [CGFloat]
    private let period: TimeInterval
    // One layer for each line width, since a layer strokes every line it holds the same.
    private var lines: [CGFloat: CAShapeLayer] = [:]

    init(dash: [CGFloat], period: TimeInterval) {
        self.dash = dash
        self.period = period
        super.init(frame: .zero)
    }

    func update(paths: [CGFloat: CGPath], colour: CGColor) {
        LayerLoop.still {
            for (width, line) in lines where paths[width] == nil {
                line.removeFromSuperlayer()
                lines[width] = nil
            }
            for (width, path) in paths {
                let line = lines[width] ?? addLine(width: width)
                line.path = path
                line.strokeColor = colour
            }
        }
    }

    override func layoutLayers() {
        lines.values.forEach { $0.frame = bounds }
    }

    override func restartLoops() {
        lines.values.forEach(flow)
    }

    private func addLine(width: CGFloat) -> CAShapeLayer {
        let line = CAShapeLayer()
        line.fillColor = nil
        line.lineWidth = width
        line.lineCap = .round
        line.lineDashPattern = dash.map { NSNumber(value: Double($0)) }
        line.frame = bounds
        line.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(line)
        lines[width] = line
        flow(line)
        return line
    }

    // The dashes travel one whole pattern each period, along the way the path was drawn.
    private func flow(_ line: CAShapeLayer) {
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = 0
        flow.toValue = -dash.reduce(0, +)
        flow.duration = period
        line.add(LayerLoop.repeating(flow, period: period), forKey: "flow")
    }
}

// The middle of the map. The ring has one arc for every session, in the colour of its
// state, so the overall picture reads before any label does. Smaller hubs drop the
// caption and then the chip, keeping the count.
struct OrbitHub: View {
    let map: HomeWorkMap
    var side: CGFloat = OrbitLayout.hubSide
    var ringWidth: CGFloat = 7
    var numberSize: CGFloat = 38

    // The space left between two arcs, measured along the ring.
    private static let arcGap: CGFloat = 7

    private var radius: CGFloat { side / 2 - ringWidth / 2 - 2 }

    var body: some View {
        let arcs = arcs
        let core = side - 2 * ringWidth - 14
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: ringWidth)
                .frame(width: radius * 2, height: radius * 2)
            ForEach(arcs.indices, id: \.self) { index in
                HubArc(start: arcs[index].start, end: arcs[index].end)
                    .stroke(arcs[index].colour,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
            }
            VStack(spacing: 2) {
                Text("\(map.runningCount)")
                    .font(.serif(numberSize, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                if side >= 120 {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if side >= 100 {
                    chip.padding(.top, 3)
                }
            }
            .frame(width: core, height: core)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().stroke(Theme.border))
            .shadow(color: .black.opacity(0.09), radius: 9, y: 8)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counted(map.runningCount, "session")) working, \(chipText)")
    }

    private var caption: String {
        if map.active.isEmpty { return "nothing running" }
        return map.runningCount == 1 ? "session working" : "sessions working"
    }

    private var chipText: String {
        let needs = map.waiting.count
        if needs > 0 { return "\(needs) need\(needs == 1 ? "s" : "") you" }
        let waits = map.backgroundWaitCount
        return waits > 0 ? "\(waits) waiting on a task" : "all clear"
    }

    @ViewBuilder private var chip: some View {
        if map.waiting.isEmpty {
            Text(chipText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Text(chipText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.attentionText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.attention.opacity(0.16)))
        }
    }

    private var arcs: [(start: CGFloat, end: CGFloat, colour: Color)] {
        let sessions = map.active.sorted { rank($0.tone) < rank($1.tone) }
        guard !sessions.isEmpty else { return [] }
        let share = 1 / CGFloat(sessions.count)
        let gap = sessions.count > 1 ? Self.arcGap / (2 * .pi * radius) : 0
        return sessions.enumerated().map { index, live in
            let start = CGFloat(index) * share
            let colour = switch live.tone {
            case .needsYou: Theme.attention
            case .waiting: Theme.dotOn.opacity(0.4)
            case .running, .idle: Theme.dotOn
            }
            return (start, start + max(share - gap, 0.002), colour)
        }
    }

    private func rank(_ tone: SessionTone) -> Int {
        switch tone {
        case .needsYou: 0
        case .running: 1
        case .waiting: 2
        case .idle: 3
        }
    }
}

// One arc of the hub's ring, given as fractions of a turn starting at the top. A reversed
// arc is drawn from its end back to its start, so it can be grown anticlockwise.
struct HubArc: Shape {
    var start: CGFloat
    var end: CGFloat
    var reversed = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let startAngle = Angle.degrees(Double(start) * 360 - 90)
        let endAngle = Angle.degrees(Double(end) * 360 - 90)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: reversed ? endAngle : startAngle,
                    endAngle: reversed ? startAngle : endAngle,
                    clockwise: reversed)
        return path
    }
}

private struct OrbitTileFace: View {
    let group: HomeWorkMap.Group
    let hovering: Bool

    var body: some View {
        let identity = group.identity
        let halo = RoundedRectangle(cornerRadius: 19)
        SidebarIdentityTile(avatar: identity.avatar, name: identity.containerName, tint: identity.tint,
                            stacked: identity.session.workspaceID != nil, side: OrbitLayout.tileSide)
            .background {
                halo
                    .fill(Theme.card)
                    .overlay(halo.stroke(hovering ? identity.tint.colour.opacity(0.5) : Theme.hairline))
                    .padding(-6)
            }
    }
}

// A project on the map. Clicking it shows the project in the sidebar, where every one of
// its sessions is listed.
private struct OrbitProjectTile: View {
    let group: HomeWorkMap.Group
    let built: Bool
    let entrance: Animation?
    let action: () -> Void
    let point: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        let identity = group.identity
        let halo = RoundedRectangle(cornerRadius: 19)
        Button(action: action) {
            OrbitTileFace(group: group, hovering: hovering)
                .contentShape(halo.inset(by: -6))
                // The pop is drawn inside the button, so the button itself is never scaled.
                .scaleEffect(built ? 1 : 0.55)
                .opacity(built ? 1 : 0)
                .animation(entrance, value: built)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            point($0)
        }
        .accessibilityLabel("\(identity.containerName), \(counted(group.sessions.count, "session"))")
        .accessibilityHint("Shows \(identity.containerName) in the sidebar")
    }
}

private struct OrbitSessionPill: View {
    let live: HomeLive
    let selected: Bool
    let left: Bool
    let built: Bool
    // A connected phone has this session open.
    let onPhone: Bool
    let entrance: Animation?
    let action: () -> Void
    let point: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pings = 0
    @State private var settles = 0

    private static let cornerRadius: CGFloat = 10

    var body: some View {
        let needs = live.needsAttention
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    MapLight(tone: live.tone)
                    Text(live.session.title)
                        .font(.system(size: 12, weight: needs ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if onPhone {
                        OnPhoneTag().transition(.opacity)
                    } else {
                        Text(live.session.agent.title)
                            .font(.mono(10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if needs {
                    request
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.attentionText)
                        .lineLimit(1)
                        .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(Theme.card)
                if needs { shape.fill(Theme.attention.opacity(0.09)) }
            }
            .background {
                if onPhone && !needs { shape.stroke(Theme.dotOn.opacity(0.12), lineWidth: 6) }
            }
            .overlay(shape.stroke(border, lineWidth: selected || (needs && hovering) ? 1.5 : 1))
            .shadow(color: (needs ? Theme.attention : .black).opacity(needs ? 0.22 : 0.1), radius: 8, y: 5)
            .contentShape(shape)
            // The slide is drawn inside the button, so the button itself never moves.
            .offset(x: built ? 0 : (left ? 14 : -14))
            .opacity(built ? 1 : 0)
            .animation(entrance, value: built)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            point($0)
        }
        .overlay { PingRing(trigger: pings, cornerRadius: Self.cornerRadius, pulses: 2) }
        .overlay { PingRing(trigger: settles, cornerRadius: Self.cornerRadius, colour: Theme.dotOn) }
        .onChange(of: needs) { _, now in
            guard !reduceMotion else { return }
            if now { pings += 1 } else { settles += 1 }
        }
        .motion(Motion.hover, value: onPhone)
        .accessibilityLabel("\(live.session.title), \(live.status), \(live.containerName)"
                            + (onPhone ? ", open on phone" : ""))
        .accessibilityHint("Shows this session's card")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // What the session is asking for, or what it has left to review.
    @ViewBuilder private var request: some View {
        if let permission = live.permission {
            if let question = permission.questions.first {
                Text(question.text)
            } else {
                let subject = permission.subject.components(separatedBy: .newlines).first ?? ""
                if permission.subjectIsMarkdown || subject.isEmpty {
                    Text(permission.title)
                } else {
                    Text("\(permission.title) ")
                        + Text(subject).font(.mono(10.5)).foregroundStyle(Color.primary)
                }
            }
        } else if live.finished {
            let summary = live.session.summary
            HStack(spacing: 6) {
                Text("Ready to review")
                if summary.added > 0 || summary.removed > 0 {
                    DiffPair(added: summary.added, removed: summary.removed, size: 10.5, spacing: 4)
                }
            }
        } else {
            Text(live.status)
        }
    }

    private var border: Color {
        if live.needsAttention {
            return selected || hovering ? Theme.attention : Theme.attention.opacity(0.55)
        }
        if selected { return Theme.accent }
        if onPhone { return Theme.dotOn.opacity(0.45) }
        return hovering ? Theme.accent.opacity(0.45) : Theme.border
    }
}

// Takes the place of the agent's name on a session a phone has open.
private struct OnPhoneTag: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone")
                .font(.system(size: 9, weight: .semibold))
            Text("On phone")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Theme.addition)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(PhoneLink.connected.fill ?? .clear))
        .fixedSize()
    }
}

// The light beside a session on the map. Waiting is drawn as a ring: the session is
// alive, but nothing is being worked on.
struct MapLight: View {
    let tone: SessionTone

    var body: some View {
        if tone == .waiting {
            Circle()
                .strokeBorder(Theme.dotOn, lineWidth: 1.6)
                .frame(width: 7, height: 7)
        } else {
            StateLight(tone: tone, size: 7)
        }
    }
}

// A ring that swells and fades around a pill: amber, twice, when a session starts asking
// for something, and green, once, when the request is answered. It plays per change
// rather than looping, so it marks the moment without nagging.
private struct PingRing: View {
    let trigger: Int
    let cornerRadius: CGFloat
    var colour = Theme.attention
    var pulses = 1

    private static let pulse: Double = 1.1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + 6)
            .stroke(colour, lineWidth: 2)
            .padding(-6)
            .keyframeAnimator(initialValue: Double(0), trigger: trigger) { ring, phase in
                // Each whole number of the phase is one pulse; at rest it sits on a whole number.
                let progress = phase - phase.rounded(.down)
                let resting = phase <= 0 || phase >= Double(pulses)
                ring.scaleEffect(0.96 + 0.22 * (1 - pow(1 - progress, 3)))
                    .opacity(resting ? 0 : 0.9 * (1 - progress))
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(Double(pulses), duration: Self.pulse * Double(pulses))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
