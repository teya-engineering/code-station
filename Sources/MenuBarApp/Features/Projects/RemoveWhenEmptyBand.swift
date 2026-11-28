import SwiftUI

// The one setting about a workspace's life. Off, it reads as a quiet note that the
// workspace stays; on, it opens a sentence that says when it goes.
struct RemoveWhenEmptyBand: View {
    let title: String
    let offNote: String
    @Binding var isOn: Bool
    @Binding var days: Int
    let oldSessionDays: Int

    @State private var detailHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                if reduceMotion { isOn = on } else { withAnimation(Motion.reveal) { isOn = on } }
            })) {
                HStack(spacing: Space.lg) {
                    WorkspaceLifeGlyph(isOn: isOn)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(title)
                            .font(Typography.body.weight(.semibold))
                        Text(note)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.appSwitch)
            .accessibilityLabel(title)
            .accessibilityHint(note)

            // Always laid out and measured, so the band grows by the sentence's real
            // height and the sheet's window glides with it rather than jumping.
            detail
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                .opacity(isOn ? 1 : 0)
                .offset(y: isOn || reduceMotion ? 0 : -3)
                .modifier(AnimatedHeight(height: isOn ? detailHeight : 0, alignment: .top))
                .clipped()
                .allowsHitTesting(isOn)
                .accessibilityHidden(!isOn)
        }
        .workspaceLifeBand()
    }

    private var note: String {
        isOn ? "On: it goes once it has had no session for a while. Its projects stay." : offNote
    }

    private var detail: some View {
        HStack(spacing: Space.md) {
            Text("Remove after")
            DayField(days: $days, accessibilityLabel: "Days the workspace may sit empty")
            Text("with no session in it.")
            if days == oldSessionDays {
                Text("Same as old sessions")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.workspaceTint.ink)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Theme.workspaceTint.fill, in: Capsule())
                    .transition(.fadeIn)
            }
            Spacer(minLength: 0)
        }
        .font(Typography.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border, lineWidth: 1))
        .motion(Motion.control, value: days == oldSessionDays)
        .padding(.leading, WorkspaceLifeGlyph.side + Space.lg)
        .padding(.top, Space.md)
    }
}

// A workspace's own removal rule, reported where it cannot be edited. The one thing to
// do from here is keep the workspace for good, which ends the rule.
struct WorkspaceRemovalNotice: View {
    let name: String
    let days: Int
    let onKeepForGood: () -> Void

    var body: some View {
        HStack(spacing: Space.lg) {
            WorkspaceLifeGlyph(isOn: true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("\(name) removes itself when it sits empty")
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(2)
                Text("After \(counted(days, "day")) with no session. Kept while it has sessions. Its projects stay.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.md)
            InlineLink(title: "Keep for good", action: onKeepForGood)
                .fixedSize()
                .accessibilityLabel("Keep \(name) for good")
        }
        .workspaceLifeBand()
    }
}

// The hourglass that heads both bands, filled with the workspace colour while removal is on.
private struct WorkspaceLifeGlyph: View {
    let isOn: Bool

    static let side = ControlHeight.md

    var body: some View {
        Image(systemName: "hourglass")
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(isOn ? Theme.workspaceTint.ink : Color.secondary)
            .frame(width: Self.side, height: Self.side)
            .background(isOn ? Theme.workspaceTint.fill : Theme.field,
                        in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityHidden(true)
    }
}

private extension View {
    // A band that sits on the footer of a sheet, set off from the body by a hairline.
    func workspaceLifeBand() -> some View {
        padding(.horizontal, Space.pane)
            .padding(.vertical, Space.lg)
            .background(Theme.statusBand)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// The sheet's window takes the size of its content but jumps straight to a new size, even
// inside an animation. Being animatable makes SwiftUI lay the content out again at every
// step of the curve, so the window is handed each height in turn and glides to the new one.
nonisolated struct AnimatedHeight: ViewModifier, Animatable {
    var height: CGFloat
    var alignment: Alignment = .center

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height, alignment: alignment)
    }
}
