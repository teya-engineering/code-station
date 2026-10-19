import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Structure

// The label over a section: mono capitals, a hairline taking the rest of the width, and
// whatever the section wants to say or offer on the right.
struct SectionRule<Trailing: View>: View {
    let title: String
    var dot: Color? = nil
    // A section about work in flight breathes with it, the same way its rows do.
    var pulses = false
    var tint: Color? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            if pulses {
                RunningDot()
            } else if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.mono(9.5, .semibold))
                .kerning(1.3)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
            trailing
        }
    }
}

extension SectionRule where Trailing == EmptyView {
    init(_ title: String, dot: Color? = nil, pulses: Bool = false, tint: Color? = nil) {
        self.init(title: title, dot: dot, pulses: pulses, tint: tint) { EmptyView() }
    }
}

// The label over a block of a form. A section, like COMMAND or ENVIRONMENT VARIABLES,
// is led by a dot, which is the only thing separating it from the last one in a plain
// scroll. A field label is smaller and quieter, since the field under it is the point.
struct SectionLabel: View {
    enum Style { case section, field }

    let text: String
    var style: Style = .section

    init(_ text: String, style: Style = .section) {
        self.text = text
        self.style = style
    }

    var body: some View {
        switch style {
        case .section:
            HStack(spacing: 7) {
                RunningDot(size: 5)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
        case .field:
            Text(text)
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
        }
    }
}

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
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if pinned && thread == .idle {
                    Circle()
                        .fill(Theme.sidebar)
                        .frame(width: 16, height: 16)
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
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

// The strip that closes a screen: what the defaults are, or what has gone stale, and the
// one link that leads to the screen where it can be changed.
struct FooterStrip<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            Text(detail)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
    }
}
