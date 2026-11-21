import SwiftUI

// The connector under an expanded sidebar row stops at its last child. Each marker is
// anchored to its row so mixed row heights keep the line and dots aligned.
private struct SidebarRailMarkerKey: PreferenceKey {
    static let defaultValue: [Anchor<CGPoint>] = []

    static func reduce(value: inout [Anchor<CGPoint>],
                       nextValue: () -> [Anchor<CGPoint>]) {
        value.append(contentsOf: nextValue())
    }
}

private enum RailMetrics {
    static let leading: CGFloat = 20
    static let top: CGFloat = 5
    static let bottom: CGFloat = 4
    static let rowSpacing: CGFloat = 5
    static let lineWidth: CGFloat = 1.5
    static let lineInset: CGFloat = 5.25
    static let lineOpacity = 0.42
    static let markerTop: CGFloat = 10
    static let markerSize = CGSize(width: 12, height: 8)
    static var markerCentre: CGFloat { markerTop + markerSize.height / 2 }
}

struct SidebarRail<Content: View>: View {
    let colour: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: RailMetrics.rowSpacing) { content }
            .backgroundPreferenceValue(SidebarRailMarkerKey.self) { markers in
                GeometryReader { proxy in
                    if let lastMarker = markers.last {
                        Rectangle()
                            .fill(colour.opacity(RailMetrics.lineOpacity))
                            .frame(width: RailMetrics.lineWidth, height: proxy[lastMarker].y)
                            .offset(x: RailMetrics.lineInset)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.leading, RailMetrics.leading)
            .padding(.top, RailMetrics.top)
            .padding(.bottom, RailMetrics.bottom)
    }
}

extension View {
    // The same rail as `SidebarRail`, drawn one row at a time so each row can stand on its
    // own in a lazy stack. A long rail held in one stack is built whole, off-screen rows
    // and all. Each row draws its own piece of the line, reaching up across the gap the
    // stack leaves above it, and the last piece stops at the last dot.
    func sidebarRailSegment(colour: Color, isFirst: Bool, isLast: Bool,
                            stackSpacing: CGFloat) -> some View {
        let top = (isFirst ? RailMetrics.top : RailMetrics.rowSpacing) - stackSpacing
        let lineStart = isFirst ? top : -stackSpacing
        return padding(.top, top)
            .padding(.bottom, isLast ? RailMetrics.bottom : 0)
            .background(alignment: .topLeading) {
                Rectangle()
                    .fill(colour.opacity(RailMetrics.lineOpacity))
                    .frame(width: RailMetrics.lineWidth,
                           height: isLast ? top + RailMetrics.markerCentre - lineStart : nil)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, lineStart)
                    .offset(x: RailMetrics.lineInset)
                    .accessibilityHidden(true)
            }
            .padding(.leading, RailMetrics.leading)
    }
}

struct SidebarRailRow<Content: View>: View {
    let colour: Color
    var selectedColour: Color? = nil
    var selected = false
    // A pinned row wears the pin in place of its dot, so the mark costs the card no
    // width. The disc behind it is the sidebar colour, which cuts the rail line around it.
    var pinned = false
    // Where the session's turn stands. While it is anything but idle the dot carries it,
    // so a pinned row gives up its pin until the turn has been seen.
    var thread: ThreadPhase = .idle
    var threadEndedCleanly = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ZStack {
                if pinned && thread == .idle {
                    Circle()
                        .fill(Theme.sidebar)
                        .frame(width: 16, height: 16)
                    Image(systemName: "pin.fill")
                        .font(Typography.micro)
                        .foregroundStyle(Theme.accent)
                } else {
                    ThreadNode(phase: thread,
                               endedCleanly: threadEndedCleanly,
                               colour: colour,
                               restingFill: selected ? selectedColour ?? colour
                                                     : colour.opacity(0.72))
                }
            }
            .frame(width: RailMetrics.markerSize.width, height: RailMetrics.markerSize.height)
            .anchorPreference(key: SidebarRailMarkerKey.self, value: .center) { [$0] }
            .padding(.top, RailMetrics.markerTop)
            .accessibilityHidden(true)

            content
                .modifier(ThreadRowEffects(phase: thread, endedCleanly: threadEndedCleanly))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
