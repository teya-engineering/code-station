import SwiftUI

// Dispatch uses the same environment names as server tagging and troubleshooting. The
// name is also the value substituted for {{env}}, while the label and danger flag control
// how that environment is presented.
struct ApiEnvironment: Identifiable, Hashable, Sendable {
    let name: String
    let label: String
    let isDangerous: Bool

    init(name: String, label: String? = nil, isDangerous: Bool = false) {
        self.name = name
        self.label = label ?? name.capitalized
        self.isDangerous = isDangerous
    }

    init(_ environment: SiteDefaults.Environment) {
        self.init(name: environment.name,
                  label: environment.label,
                  isDangerous: environment.isDangerous)
    }

    var id: String { name }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    // Only {{env}} is substituted. Anything else in braces stays as typed, so a typo
    // is visible in the resolved URL instead of quietly becoming an empty string.
    func resolve(_ template: String) -> String {
        template.replacingOccurrences(of: "{{env}}", with: name)
    }

    // The foreground accent stays visible on adaptive surfaces.
    var accent: Color { isDangerous ? Theme.deletion : Theme.accent }

    // Filled controls need a deeper colour because their labels are white.
    var accentFill: Color { isDangerous ? Theme.deletion : Theme.accentFill }

    // The brighter accent for the rail, the dots and the resolved {{env}} segment.
    var brightAccent: Color { isDangerous ? Theme.deletion : Theme.addition }

    // The pill tone that wears the same fill, for the buttons that act in this environment.
    var buttonTone: ButtonTone { isDangerous ? .danger : .green }
}

// The track that picks an environment: one pill per configured environment, with a
// fill in the picked one's colour that slides to the pick. A live environment carries a
// red dot before it is picked, so the warning is there before the click.
struct EnvironmentPills: View {
    let environments: [ApiEnvironment]
    let selected: ApiEnvironment
    let choose: (ApiEnvironment) -> Void

    @Namespace private var track
    @FocusState private var focused: ApiEnvironment?

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(environments) { env in
                EnvironmentPill(env: env, selected: env == selected, focused: focused == env, track: track) {
                    choose(env)
                }
                .focusable()
                .focused($focused, equals: env)
                .focusEffectDisabled()
                .onKeyPress(keys: [.space, .return]) { _ in choose(env); return .handled }
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in step(from: env, by: key.key == .rightArrow ? 1 : -1) }
            }
        }
        .padding(Space.xxs)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
        .motion(Motion.control, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send destination")
    }

    private func step(from env: ApiEnvironment, by offset: Int) -> KeyPress.Result {
        guard let index = environments.firstIndex(of: env), environments.count > 1 else { return .ignored }
        let next = environments[(index + offset + environments.count) % environments.count]
        choose(next)
        focused = next
        return .handled
    }
}

private struct EnvironmentPill: View {
    let env: ApiEnvironment
    let selected: Bool
    let focused: Bool
    let track: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if env.isDangerous {
                    Circle()
                        .fill(selected ? Theme.onFill : Theme.deletion)
                        .frame(width: DispatchMetrics.dot, height: DispatchMetrics.dot)
                }
                Text(env.label)
                    .font(Typography.label)
                    .fixedSize()
            }
            .foregroundStyle(selected ? Theme.onFill : hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, Space.lg)
            .frame(height: ControlHeight.md)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(env.accentFill)
                        .elevation(.raised)
                        .matchedGeometryEffect(id: "fill", in: track)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { FocusRingStroke(focused: focused, cornerRadius: Radius.control) }
        .accessibilityLabel("\(env.label), environment key: \(env.name)" + (env.isDangerous ? ", live environment" : ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        // Hung outside the lift, since a hint cannot be laid out under a scale.
        .appTooltip(env.isDangerous ? "Live data. Every send asks first." : nil)
    }
}
