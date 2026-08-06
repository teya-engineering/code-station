import SwiftUI

// The two places a request can be sent. The requests themselves are shared; an
// environment brings its own credentials, its own {{env}} value, and the colour the
// whole sheet takes on so the active side is legible at a glance.
enum ApiEnvironment: String, Codable, CaseIterable, Identifiable {
    case staging, production

    var id: String { rawValue }

    var label: String {
        switch self {
        case .staging: "Staging"
        case .production: "Production"
        }
    }

    // What {{env}} becomes in a URL sent from this environment.
    var envValue: String {
        switch self {
        case .staging: "dev"
        case .production: "prd"
        }
    }

    // Only {{env}} is substituted. Anything else in braces stays as typed, so a typo
    // is visible in the resolved URL instead of quietly becoming an empty string.
    func resolve(_ template: String) -> String {
        template.replacingOccurrences(of: "{{env}}", with: envValue)
    }

    // The deep accent for buttons, links and the selected segment.
    var accent: Color {
        switch self {
        case .staging: Theme.accent
        case .production: Theme.deletion
        }
    }

    // The brighter accent for the rail, the dots and the resolved {{env}} segment.
    var brightAccent: Color {
        switch self {
        case .staging: Theme.addition
        case .production: Theme.deletion
        }
    }
}
