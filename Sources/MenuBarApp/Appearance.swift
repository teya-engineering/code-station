import AppKit

enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // Set on the application because the manager window and every sheet are AppKit windows
    // we create ourselves at different times.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

enum SidebarIconSet: String {
    case monograms
    case diceBear
}

enum SidebarIconMotion: Equatable {
    case still
    case animated
}

enum DiceBearAvatarStyle: String, CaseIterable, Identifiable {
    case squircles
    case planets
    case shapes
    case blobs
    case waves
    case sprouts
    case stripes
    case landscape
    case weave
    case critters
    case moods
    case botttsNeutral = "bottts-neutral"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .squircles: "Squircles"
        case .planets: "Planets"
        case .shapes: "Shapes"
        case .blobs: "Blobs"
        case .waves: "Waves"
        case .sprouts: "Sprouts"
        case .stripes: "Stripes"
        case .landscape: "Landscape"
        case .weave: "Weave"
        case .critters: "Critters"
        case .moods: "Moods"
        case .botttsNeutral: "Bottts Neutral"
        }
    }

    var supportsAnimation: Bool {
        switch self {
        case .stripes, .weave, .botttsNeutral: false
        default: true
        }
    }

    var usesArtworkPrimaryColour: Bool {
        switch self {
        case .shapes, .landscape, .weave: false
        default: true
        }
    }
}
