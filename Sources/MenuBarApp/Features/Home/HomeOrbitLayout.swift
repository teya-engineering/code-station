import SwiftUI

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
    // The pills are what Home is opened to click, so the whole order is played at this
    // share of its natural pace. Each part still moves at its own speed; it only starts
    // sooner, and a map of a dozen sessions is ready in well under two seconds.
    static let pace = 0.6

    let ringDone: Double
    private let pillCount: Int

    init(layout: OrbitLayout) {
        ringDone = (Double(layout.steps) * 0.055 + 0.45) * Self.pace
        pillCount = layout.pills.count
    }

    func arc(_ step: Int) -> Double { Double(step) * 0.055 * Self.pace }
    func projectRing(_ index: Int) -> Double { max(0, ringDone - 0.3 * Self.pace) + Double(index) * 0.04 * Self.pace }
    func tile(_ index: Int) -> Double { ringDone + (0.38 + Double(index) * 0.07) * Self.pace }
    func pill(_ index: Int) -> Double { leaves + (0.2 + Double(index) * 0.045) * Self.pace }
    var more: Double { leaves + 0.4 * Self.pace }
    var flow: Double { pill(pillCount) + 0.3 * Self.pace }

    func wire(_ wire: OrbitLayout.Wire) -> Double {
        wire.trunk ? ringDone + Double(wire.order) * 0.07 * Self.pace
            : leaves + Double(wire.order) * 0.045 * Self.pace
    }

    private var leaves: Double { ringDone + 0.6 * Self.pace }

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
