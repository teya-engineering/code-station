import SwiftUI

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
        .motion(Motion.hover, value: spotlight)
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
            .transition(.popover(reduceMotion: reduceMotion))
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
            .font(Typography.label)
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
                .font(Typography.detail.weight(.medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: OrbitLayout.pillHeight / 2)
                .contentShape(Capsule())
                .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
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
        .onPointerHover {
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
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.md) {
                    MapLight(tone: live.tone)
                    Text(live.session.title)
                        .font(Typography.detail.weight(needs ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if onPhone {
                        OnPhoneTag().transition(.opacity)
                    } else {
                        Text(live.session.agent.title)
                            .font(Typography.data)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if needs {
                    request
                        .font(Typography.caption)
                        .foregroundStyle(Theme.attentionText)
                        .lineLimit(1)
                        .padding(.leading, Space.xl)
                }
            }
            .padding(.horizontal, Space.lg)
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
        .onPointerHover {
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
                        + Text(subject).font(Typography.data).foregroundStyle(Color.primary)
                }
            }
        } else if live.finished {
            let summary = live.session.summary
            HStack(spacing: Space.sm) {
                Text("Ready to review")
                if summary.added > 0 || summary.removed > 0 {
                    DiffPair(added: summary.added, removed: summary.removed, size: Typography.Size.caption, spacing: Space.xs)
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
        HStack(spacing: Space.xs) {
            Image(systemName: "iphone")
                .font(.system(size: 9, weight: .semibold))
            Text("On phone")
                .font(Typography.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.addition)
        .padding(.horizontal, Space.sm)
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
