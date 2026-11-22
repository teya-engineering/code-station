import SwiftUI

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
            VStack(spacing: Space.xxs) {
                Text("\(map.inProgressCount)")
                    .font(.serif(numberSize, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                if side >= 120 {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if side >= 100 {
                    chip.padding(.top, Space.xxs)
                }
            }
            .frame(width: core, height: core)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().stroke(Theme.border))
            .shadow(color: .black.opacity(0.09), radius: 9, y: 8)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counted(map.inProgressCount, "session")) in progress, \(chipText)")
    }

    private var caption: String {
        if map.active.isEmpty { return "nothing running" }
        return map.inProgressCount == 1 ? "session in progress" : "in progress"
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
                .font(Font.system(size: Typography.Size.micro))
                .foregroundStyle(.secondary)
        } else {
            Text(chipText)
                .font(Typography.micro)
                .foregroundStyle(Theme.attentionText)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
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
