import SwiftUI
import CodeStationCore

// The code that is out, as the orbit tells it: whether a phone has picked it up and which
// session it has open. Kept apart from the views so the words can be checked without
// drawing anything.
struct OrbitPhoneLink: Equatable {
    let connected: Bool
    // The session the phone is reading and its title, when it has one open.
    let openSession: UUID?
    let openTitle: String?

    init(connected: Bool, openSession: UUID?, openTitle: String?) {
        self.connected = connected
        self.openSession = connected ? openSession : nil
        self.openTitle = self.openSession == nil ? nil : openTitle
    }

    var link: PhoneLink { connected ? .connected : .waiting }

    var state: String { link.word ?? "" }

    // The second line in three parts, so the name can stand out from the words around it.
    var reach: (lead: String, name: String, tail: String) {
        if let openTitle { return ("Open on ", openTitle, "") }
        if connected { return ("Can reach ", "every project", "") }
        return ("Code is out for every project", "", "")
    }

    var reachText: String {
        let reach = reach
        return reach.lead + reach.name + reach.tail
    }

    static let tooltip = "Reaches every project"
    static let action = "Show the code or stop sharing"

    var accessibilityLabel: String { "\(state). \(reachText). \(Self.action)." }
}

// What the phone lights on the map: the path from the ring to the session it has open.
struct OrbitPhoneReach: Equatable {
    var wires: Set<String> = []
    var sessions: Set<UUID> = []

    init() {}

    init(link: OrbitPhoneLink?, map: HomeWorkMap) {
        guard let open = link?.openSession else { return }
        sessions.insert(open)
        if let live = map.active.first(where: { $0.id == open }) {
            wires.formUnion(["hub:\(live.containerID)", "session:\(live.id)"])
        }
    }
}

// The pill above the ring for the code that is out. It opens the same dialog as the Home
// phone pill, where the code can be shown again or taken back.
struct OrbitPhoneBeacon: View {
    let link: OrbitPhoneLink
    let reachWidth: CGFloat
    let action: () -> Void

    @State private var hovering = false

    static let height: CGFloat = 46

    var body: some View {
        let reach = link.reach
        Button(action: action) {
            HStack(spacing: 10) {
                seat
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.state)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(link.link.tint)
                    (Text(reach.lead).foregroundStyle(.secondary)
                        + Text(reach.name).fontWeight(.medium).foregroundStyle(.primary)
                        + Text(reach.tail).foregroundStyle(.secondary))
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: reachWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                    .offset(x: hovering ? 2 : 0)
                    .padding(.leading, 2)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: Self.height)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.border))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.08), radius: hovering ? 12 : 9, y: hovering ? 7 : 5)
            .contentShape(Capsule())
            // The lift is drawn inside the button, so the button itself never moves.
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip(delay: .zero) {
            Tooltip(title: OrbitPhoneLink.tooltip, subtitle: OrbitPhoneLink.action)
        }
        .accessibilityLabel(link.accessibilityLabel)
    }

    // A connected phone sends out a slow wave from its seat. A code still waiting breathes
    // instead, so the two read apart even without their colours.
    private var seat: some View {
        Image(systemName: "iphone")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(link.link.tint)
            .frame(width: 34, height: 34)
            .background {
                switch link.link {
                case .connected:
                    BreathingCircle(colour: Theme.dotOn.opacity(0.35), restingScale: 1, fullScale: 1.45,
                                    restingOpacity: 0.6, fullOpacity: 0)
                    Circle().fill(link.link.fill ?? .clear)
                case .waiting, .none:
                    BreathingCircle(colour: link.link.fill ?? .clear, period: 2.2,
                                    restingOpacity: 1, fullOpacity: 0.45)
                }
            }
            .accessibilityHidden(true)
    }
}

// The line from a phone pill down into the top of the ring. A live one draws itself in and
// then carries small dots down, for what the phone sends landing in the app. A code still
// waiting is a still, dotted amber line.
struct OrbitPhoneSignal: View {
    let link: PhoneLink
    let start: CGPoint
    let end: CGPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let dy = end.y - start.y
        let connector = MapConnector(start: start,
                                     control1: CGPoint(x: start.x, y: start.y + dy * 0.55),
                                     control2: CGPoint(x: end.x, y: end.y - dy * 0.55),
                                     end: end)
        let live = link == .connected
        let tint = live ? Theme.dotOn : Theme.attention
        ZStack {
            connector
                .trim(from: 0, to: drawn || !live ? 1 : 0)
                .stroke(live ? Theme.dotOn : Theme.attention.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: live ? [] : [2, 6]))
            if live && !reduceMotion {
                FlowingWires(paths: [4: connector.path(in: .zero).cgPath], colour: Theme.dotOn,
                             dash: [0.5, 44], period: 1.2)
                    .opacity(drawn ? 1 : 0)
            }
            Circle()
                .fill(Theme.card)
                .overlay(Circle().stroke(tint, lineWidth: 1.6))
                .frame(width: 7, height: 7)
                .position(end)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: draw)
        .onChange(of: live) { _, now in if now { draw() } }
    }

    // The pill drops in first and the line follows it down a beat later.
    private func draw() {
        guard !drawn else { return }
        if reduceMotion {
            drawn = true
        } else {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9).delay(0.24)) { drawn = true }
        }
    }
}

// One ring that swells out of the hub and fades, the moment a phone joins.
struct OrbitPhoneRipple: View {
    let trigger: Int

    var body: some View {
        Circle()
            .stroke(Theme.dotOn, lineWidth: 2)
            .frame(width: 2 * OrbitLayout.projectRingRadius, height: 2 * OrbitLayout.projectRingRadius)
            .keyframeAnimator(initialValue: Double(1), trigger: trigger) { ring, progress in
                ring.scaleEffect(1 + 0.55 * (1 - pow(1 - progress, 3)))
                    .opacity(progress >= 1 ? 0 : 0.55 * (1 - progress))
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 1.4)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
