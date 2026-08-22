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
    var rawValue: String { name }
    var envValue: String { name }

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
}
