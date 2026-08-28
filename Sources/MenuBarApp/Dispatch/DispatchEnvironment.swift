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

// The row that picks an environment: one pill per configured environment, the chosen
// one filled in its own colour. Dispatch's header and the Environments sheet both pick
// with it, so a switch reads the same wherever it is made.
struct EnvironmentPills: View {
    let environments: [ApiEnvironment]
    let selected: ApiEnvironment
    // The Environments sheet also shows what {{env}} resolves to, beside a label that
    // differs from it.
    var showsNames = false
    let choose: (ApiEnvironment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(environments) { env in
                    EnvironmentPill(env: env, selected: env == selected, showsName: showsNames) {
                        choose(env)
                    }
                }
            }
            .padding(3)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
    }
}

private struct EnvironmentPill: View {
    let env: ApiEnvironment
    let selected: Bool
    let showsName: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(env.label)
                    .font(.system(size: 12, weight: .semibold))
                if showsName, env.label != env.name {
                    Text(env.name)
                        .font(.mono(10, .medium))
                        .opacity(0.72)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? env.accentFill : (hovering ? Theme.field : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
