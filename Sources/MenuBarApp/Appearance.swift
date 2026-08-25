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

enum SidebarIconSet: String, CaseIterable, Identifiable {
    case monograms
    case diceBear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .monograms: "Monograms"
        case .diceBear: "DiceBear"
        }
    }
}

enum SidebarIconMotion: String, CaseIterable, Identifiable {
    case still
    case animated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .still: "Still"
        case .animated: "Animated"
        }
    }
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
        }
    }

    var supportsAnimation: Bool { self != .stripes }

    static func available(for motion: SidebarIconMotion) -> [Self] {
        switch motion {
        case .still: allCases
        case .animated: allCases.filter(\.supportsAnimation)
        }
    }
}
