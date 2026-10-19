import SwiftUI
import CodeStationCore

// The middle of the orbit. The inner ring has one arc for every session, in the colour of
// its state, and the thin outer ring one segment for every project, in its tint. Arcs of
// running sessions carry moving dashes, and the count of working sessions sits inside.
struct OrbitRing: View {
    let layout: OrbitLayout
    let map: HomeWorkMap
    let built: Bool
    let opening: OrbitOpening
    let spotlight: OrbitSpotlight?
    let select: (UUID) -> Void
    let point: (OrbitSpotlight, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointedArc: OrbitSpotlight?

    private static let side = OrbitLayout.hubSide

    var body: some View {
        let ring = 2 * OrbitLayout.ringRadius
        let projectRing = 2 * OrbitLayout.projectRingRadius
        let gap = OrbitLayout.arcGap
        ZStack {
            Circle()
                .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 2 * OrbitLayout.orbitRadius, height: 2 * OrbitLayout.orbitRadius)
                .allowsHitTesting(false)
            Circle()
                .stroke(Theme.hairline, lineWidth: OrbitLayout.ringWidth)
                .frame(width: ring, height: ring)
                .allowsHitTesting(false)

            ForEach(Array(layout.nodes.enumerated()), id: \.element.id) { index, node in
                HubArc(start: node.segment.lowerBound + gap, end: node.segment.upperBound - gap,
                       reversed: node.left)
                    .trim(from: 0, to: built ? 1 : 0)
                    .stroke(node.group.identity.tint.colour,
                            style: StrokeStyle(lineWidth: OrbitLayout.projectRingWidth, lineCap: .round))
                    .animation(reduceMotion ? nil : OrbitOpening.draw.delay(opening.projectRing(index)),
                               value: built)
                    .frame(width: projectRing, height: projectRing)
                    .opacity(OrbitSpotlight.opacity(spotlight, group: node.group.id))
                    .allowsHitTesting(false)
            }

            ForEach(layout.arcs) { arc in
                let live = arc.live
                let spot = OrbitSpotlight.session(live.id, group: live.containerID)
                RingArc(arc: arc, built: built,
                        entrance: reduceMotion ? nil : OrbitOpening.draw.delay(opening.arc(arc.step)),
                        hot: spotlight == spot) {
                    select(live.id)
                }
                    .frame(width: ring, height: ring)
                    .opacity(OrbitSpotlight.opacity(spotlight, group: live.containerID, session: live.id))
            }

            if !reduceMotion {
                sweeps
                    .opacity(built ? 1 : 0)
                    .animation(.easeOut(duration: 0.5).delay(opening.flow), value: built)
            }

            VStack(spacing: 4) {
                RollingCount(value: built ? Double(map.runningCount) : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: opening.ringDone), value: built)
                Text(map.runningCount == 1 ? "session working" : "working")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        }
        .frame(width: Self.side, height: Self.side)
        .onContinuousHover { phase in
            var now: OrbitSpotlight?
            if case .active(let location) = phase, let arc = layout.arc(at: location) {
                now = .session(arc.id, group: arc.live.containerID)
            }
            guard now != pointedArc else { return }
            if let pointedArc { point(pointedArc, false) }
            if let now { point(now, true) }
            pointedArc = now
        }
    }

    // Dashes moving round the arc of every running session, lit and dimmed with it.
    private var sweeps: some View {
        let running = layout.arcs.filter { $0.live.tone == .running }
        let lit = running.filter {
            OrbitSpotlight.opacity(spotlight, group: $0.live.containerID, session: $0.id) == 1
        }
        let dim = running.filter {
            OrbitSpotlight.opacity(spotlight, group: $0.live.containerID, session: $0.id) < 1
        }
        return ZStack {
            if !lit.isEmpty {
                FlowingWires(paths: [2: path(lit)], colour: Theme.card.opacity(0.85),
                             dash: [1.5, 9], period: 1.4)
            }
            if !dim.isEmpty {
                FlowingWires(paths: [2: path(dim)], colour: Theme.card.opacity(0.85),
                             dash: [1.5, 9], period: 1.4)
                    .opacity(0.2)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func path(_ arcs: [OrbitLayout.Arc]) -> CGPath {
        let path = CGMutablePath()
        let frame = CGRect(x: Self.side / 2 - OrbitLayout.ringRadius, y: Self.side / 2 - OrbitLayout.ringRadius,
                           width: 2 * OrbitLayout.ringRadius, height: 2 * OrbitLayout.ringRadius)
        for arc in arcs {
            let shape = HubArc(start: arc.start + OrbitLayout.arcGap, end: arc.end - OrbitLayout.arcGap)
            path.addPath(shape.path(in: frame).cgPath)
        }
        return path
    }

    private var summary: String {
        var parts = ["\(counted(map.runningCount, "session")) working"]
        let needs = map.waiting.count
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        let waits = map.backgroundWaitCount
        if waits > 0 { parts.append("\(waits) waiting on a task") }
        return parts.joined(separator: ", ")
    }
}

// One session's arc on the ring. It flares when the session starts asking for something,
// and turns green in place when the request is answered.
private struct RingArc: View {
    let arc: OrbitLayout.Arc
    let built: Bool
    let entrance: Animation?
    let hot: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flares = 0

    var body: some View {
        let shape = HubArc(start: arc.start + OrbitLayout.arcGap, end: arc.end - OrbitLayout.arcGap,
                           reversed: arc.left)
        let width = hot ? OrbitLayout.ringWidth + 6 : OrbitLayout.ringWidth
        KeyframeAnimator(initialValue: CGFloat(0), trigger: flares) { swell in
            shape
                .trim(from: 0, to: built ? 1 : 0)
                .stroke(colour, lineWidth: width + swell)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(10, duration: 0.33)
                CubicKeyframe(0, duration: 0.77)
                CubicKeyframe(10, duration: 0.33)
                CubicKeyframe(0, duration: 0.77)
            }
        }
        .animation(entrance, value: built)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: arc.live.tone)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: hot)
        .contentShape(shape.stroke(lineWidth: OrbitLayout.ringWidth + 6))
        .onTapGesture(perform: select)
        .onChange(of: arc.live.needsAttention) { _, now in
            if now && !reduceMotion { flares += 1 }
        }
        .accessibilityHidden(true)
    }

    private var colour: Color {
        switch arc.live.tone {
        case .needsYou: Theme.attention
        case .waiting: Theme.dotOff
        case .running, .idle: Theme.dotOn
        }
    }
}

// The working count, rolling up from nothing as the ring draws.
nonisolated private struct RollingCount: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(.serif(50, .medium))
            .monospacedDigit()
    }
}
