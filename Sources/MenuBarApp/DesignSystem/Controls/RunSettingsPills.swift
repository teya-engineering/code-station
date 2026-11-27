import SwiftUI

// MARK: - Model

struct ModelPill: View {
    let title: String
    var locked = false

    var body: some View {
        BarPill {
            HStack(spacing: Space.sm) {
                Image(systemName: "cpu")
                    .font(Typography.label)
                    .foregroundStyle(.secondary)
                RollingText(title, font: Typography.label)
                    .foregroundStyle(locked ? .secondary : .primary)
                LockChevron(locked: locked)
            }
        }
        .motion(Motion.reveal, value: locked)
    }
}

// MARK: - Effort

// Four bars, lit from the left as the level rises. Each bar changes on its own beat, in
// the direction the level moved, so the meter visibly fills up or drains down.
struct EffortMeter: View {
    let lit: Int
    var height: CGFloat = 14

    @State private var previous: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bars = 4

    // How many bars a level lights. No choice lights none; the lowest level lights one
    // and the highest all four, with whatever lies between spread evenly across them, so
    // an agent with five levels and one with three both read on the same scale.
    static func lit(for level: String?, among levels: [String]) -> Int {
        guard let level, let index = levels.firstIndex(of: level) else { return 0 }
        guard levels.count > 1 else { return bars }
        let share = Double(index) / Double(levels.count - 1)
        return 1 + Int((share * Double(bars - 1)).rounded())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.18) {
            ForEach(0..<Self.bars, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar < lit ? Theme.accent : Theme.settingsBorder)
                    .frame(width: height * 0.28, height: barHeight(bar))
                    .animation(reduceMotion ? nil : Motion.pop.delay(delay(of: bar)), value: lit)
            }
        }
        .frame(height: height, alignment: .bottom)
        .onChange(of: lit, initial: true) { _, now in previous = now }
        .accessibilityHidden(true)
    }

    // The bars climb from a quarter of the meter's height to all of it.
    private func barHeight(_ bar: Int) -> CGFloat {
        let share = CGFloat(bar + 1) / CGFloat(Self.bars)
        return height * (0.25 + 0.75 * share)
    }

    private func delay(of bar: Int) -> Double {
        let from = previous ?? lit
        let step = lit > from ? bar - from : from - 1 - bar
        return Double(max(0, step)) * 0.04
    }
}

struct EffortPill: View {
    let title: String
    let lit: Int
    var form = false
    // Held for the length of a turn: the words go quiet and the chevron becomes a clock.
    var locked = false

    // The level as it was before this change, read while the change is being drawn so
    // the word knows which way to roll.
    @State private var previous: Int?
    // A disabled pill has no menu to open, so it shows no chevron.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        BarPill(form: form) {
            HStack(spacing: Space.sm) {
                EffortMeter(lit: lit)
                RollingText(title, rising: lit >= (previous ?? lit),
                            font: Typography.label)
                    .foregroundStyle(locked ? .secondary : .primary)
                if form { Spacer(minLength: 0) }
                if isEnabled || locked { LockChevron(locked: locked) }
            }
        }
        .motion(Motion.reveal, value: locked)
        .onChange(of: lit, initial: true) { _, now in previous = now }
    }
}

// MARK: - Asks before

// How far the agent is trusted to act without asking, as the colour of its shield. Green
// asks before everything, plain only asks about risky steps, amber lets edits through,
// and blue changes nothing at all. Red is kept for access with no limits whatever.
enum TrustTone: Equatable {
    case asksEverything
    case risky
    case allowsEdits
    case plans
    case unrestricted

    var ink: Color {
        switch self {
        case .asksEverything: Theme.addition
        case .risky: .primary
        case .allowsEdits: Theme.attentionText
        case .plans: Theme.plan
        // The red read as words, which has to carry on its own tint in dark mode.
        case .unrestricted: Theme.warningText
        }
    }

    var fill: Color {
        switch self {
        case .asksEverything: Theme.addition.opacity(0.14)
        case .risky: Theme.field
        case .allowsEdits: Theme.attention.opacity(0.18)
        case .plans: Theme.plan.opacity(0.14)
        case .unrestricted: Theme.deletion.opacity(0.14)
        }
    }
}

struct ShieldPill: View {
    let tone: TrustTone
    let title: String
    var form = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BarPill(fill: tone.fill, form: form) {
            HStack(spacing: Space.sm) {
                Image(systemName: "shield")
                    .font(Typography.label)
                    // The swell is on the glyph inside the label: the pill around it hosts
                    // AppKit views that cannot be laid out under a transform.
                    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : tone) { glyph, scale in
                        glyph.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.25, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.23, spring: .bouncy)
                    }
                RollingText(title, font: Typography.label)
                if form { Spacer(minLength: 0) }
                MenuChevron(size: 8, tint: tone.ink.opacity(0.7))
            }
            .foregroundStyle(tone.ink)
        }
        .motion(Motion.pop, value: tone)
    }
}

// MARK: - Shared pieces

// A menu control's chevron, or a clock while the control is held until a turn ends. The
// two symbols swap in place, so the control says it is waiting without moving.
struct LockChevron: View {
    let locked: Bool
    var size: CGFloat = 8

    @Environment(\.menuIsOpen) private var open

    var body: some View {
        Image(systemName: locked ? "clock" : "chevron.down")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentTransition(.symbolEffect(.replace))
            .rotationEffect(.degrees(open && !locked ? 180 : 0))
            .motion(Motion.reveal, value: open)
            .motion(Motion.control, value: locked)
            .accessibilityHidden(true)
    }
}

extension View {
    // The control lifts a point or two and a brand-coloured sweep crosses it once, each
    // control a beat after the one before, so a row unlocking reads left to right. Each
    // new `wave` plays it once; nothing plays under Reduce Motion.
    func unlockWave(_ wave: Int, index: Int) -> some View {
        modifier(UnlockWave(wave: wave, index: index))
    }
}

private struct UnlockWave: ViewModifier {
    let wave: Int
    let index: Int

    @State private var lifted = false
    @State private var sweep: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var delay: Double { Double(index) * Motion.stagger * 3 }

    func body(content: Content) -> some View {
        content
            .offset(y: lifted ? -Space.xxs : 0)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [Theme.brand.opacity(0), Theme.brand.opacity(0.55),
                                            Theme.brand.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: sweep * geometry.size.width)
                        .opacity(sweep > -1 && sweep < 1 ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: ControlHeight.md))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: wave) { _, _ in
                guard !reduceMotion else { return }
                sweep = -0.6
                withAnimation(Motion.draw.delay(delay)) { sweep = 1 }
                withAnimation(Motion.pop.delay(delay)) {
                    lifted = true
                } completion: {
                    withAnimation(Motion.pop) { lifted = false }
                }
            }
    }
}

// The rounded pill every menu control on the bar is drawn on, so they share one height
// and one way of answering the pointer.
struct BarPill<Content: View>: View {
    var fill: Color = Theme.field
    var form = false
    @ViewBuilder let content: Content

    @State private var hovering = false
    @Environment(\.menuIsOpen) private var open
    // A pill with nothing to open is drawn dimmed and does not answer the pointer, the
    // same way the shared buttons do.
    @Environment(\.isEnabled) private var isEnabled

    init(fill: Color = Theme.field, form: Bool = false, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.form = form
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: form ? Radius.control : ControlHeight.md)
    }

    var body: some View {
        content
            .lineLimit(1)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: form ? .infinity : nil)
            .frame(height: form ? ControlHeight.xl : ControlHeight.md)
            .background(shape.fill(fill))
            .overlay(shape.fill(Color.primary.opacity((hovering && isEnabled) || open ? 0.05 : 0)))
            .overlay(shape.strokeBorder(form ? Theme.border : .clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .fixedSize(horizontal: !form, vertical: true)
            .hoverLift(hovering && isEnabled)
            .onPointerHover { hovering = $0 }
            .motion(Motion.hover, value: hovering)
    }
}

// A word that changes rolls: the old one goes up and out, the new one comes in from
// below, and the width follows. A level that falls rolls the other way.
struct RollingText: View {
    let text: String
    var rising = true
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, rising: Bool = true, font: Font) {
        self.text = text
        self.rising = rising
        self.font = font
    }

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .fixedSize()
                .id(text)
                .transition(reduceMotion ? AnyTransition.opacity : .asymmetric(
                    insertion: .move(edge: rising ? .bottom : .top).combined(with: .opacity),
                    removal: .move(edge: rising ? .top : .bottom).combined(with: .opacity)))
        }
        .clipped()
        // Not `.motion`, which would stand still under Reduce Motion: there the words
        // still cross-fade, they only stop rolling.
        .animation(reduceMotion ? Motion.reveal : Motion.control, value: text)
    }
}
