import SwiftUI

// The whole trace in a strip, a lane per depth, with the part the waterfall shows marked
// on it. Dragging across it zooms the waterfall in; dragging the marked part or its edges
// moves it; a double click shows the whole trace again.
struct TraceOverview: View {
    let trace: Trace
    @Binding var window: ClosedRange<Int64>?
    @Binding var dragging: Bool
    let colour: (String) -> Color

    private enum Drag {
        case new(anchor: Int64)
        case left
        case right
        case move(grab: Int64, start: ClosedRange<Int64>)
    }

    @State private var drag: Drag?
    private static let height: CGFloat = 48
    private static let lanes = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    lanes
                    if let window { marks(window, width: width) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in dragged(value, width: width) }
                    .onEnded { _ in
                        drag = nil
                        dragging = false
                    })
                .onTapGesture(count: 2) { window = nil }
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.sunken))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trace overview")
            .accessibilityValue(caption)
            .accessibilityAction(named: "Show whole trace") { window = nil }
            HStack(spacing: Space.md) {
                Text(caption)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                if window != nil {
                    InlineLink(title: "Show whole trace", size: Typography.Size.detail) { window = nil }
                }
            }
        }
        .appTooltip("Drag to zoom into part of the trace")
    }

    var caption: String {
        guard let window else { return "Whole trace. Drag across it to zoom in." }
        return "\(Trace.offsetText(window.lowerBound - trace.startNanos)) to "
            + "\(Trace.offsetText(window.upperBound - trace.startNanos)), "
            + "\(counted(trace.spanCount(in: window), "span")) in view"
    }

    private var lanes: some View {
        let depth = min((trace.rows.map(\.depth).max() ?? 0) + 1, Self.lanes)
        let total = Double(max(trace.durationNanos, 1))
        return Canvas { context, size in
            let laneHeight = (size.height - 10) / CGFloat(depth)
            for row in trace.rows {
                let span = row.span
                let x = CGFloat(Double(span.startNanos - trace.startNanos) / total) * size.width
                let width = max(CGFloat(Double(span.durationNanos) / total) * size.width, 1.2)
                let y = 5 + CGFloat(min(row.depth, depth - 1)) * laneHeight
                let tint = span.isError ? Theme.deletion : colour(span.service)
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width,
                                                      height: laneHeight * 0.62),
                                  cornerRadius: 1),
                             with: .color(tint.opacity(row.hasChildren ? 0.38 : 1)))
            }
        }
    }

    private func marks(_ window: ClosedRange<Int64>, width: CGFloat) -> some View {
        let left = x(window.lowerBound, width)
        let right = x(window.upperBound, width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.card.opacity(0.7)).frame(width: max(left, 0))
            Rectangle().fill(Theme.card.opacity(0.7))
                .frame(width: max(width - right, 0))
                .offset(x: right)
            RoundedRectangle(cornerRadius: Radius.tag)
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: max(right - left, 2))
                .offset(x: left)
            ForEach([left, right], id: \.self) { edge in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 18)
                    .offset(x: edge - 2, y: Self.height / 2 - 9)
            }
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }

    private func x(_ nanos: Int64, _ width: CGFloat) -> CGFloat {
        CGFloat(Double(nanos - trace.startNanos) / Double(max(trace.durationNanos, 1))) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Int64 {
        let share = min(max(Double(x / max(width, 1)), 0), 1)
        return trace.startNanos + Int64(share * Double(trace.durationNanos))
    }

    private func dragged(_ value: DragGesture.Value, width: CGFloat) {
        dragging = true
        if drag == nil {
            let start = value.startLocation.x
            if let window {
                let left = x(window.lowerBound, width)
                let right = x(window.upperBound, width)
                if abs(start - left) <= 6 {
                    drag = .left
                } else if abs(start - right) <= 6 {
                    drag = .right
                } else if start > left && start < right {
                    drag = .move(grab: time(start, width), start: window)
                } else {
                    drag = .new(anchor: time(start, width))
                }
            } else {
                drag = .new(anchor: time(start, width))
            }
        }
        let now = time(value.location.x, width)
        let current = window ?? trace.wholeWindow
        switch drag {
        case .new(let anchor):
            window = trace.zoomWindow(anchor, now)
        case .left:
            window = trace.zoomWindow(min(now, current.upperBound), current.upperBound)
        case .right:
            window = trace.zoomWindow(current.lowerBound, max(now, current.lowerBound))
        case .move(let grab, let start):
            let span = start.upperBound - start.lowerBound
            let lower = min(max(start.lowerBound + now - grab, trace.startNanos), trace.endNanos - span)
            window = trace.zoomWindow(lower, lower + span)
        case nil:
            break
        }
    }
}
