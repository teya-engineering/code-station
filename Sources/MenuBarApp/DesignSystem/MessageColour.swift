import AppKit
import SwiftUI
import CodeStationCore

// The colour behind what a person sends in a session. The bubble's shape is fixed; only
// its colours are a choice.
enum MessageColour: String, CaseIterable, Identifiable {
    case projectIcon
    case stone
    case paper
    case lemon
    case leaf
    case ink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .projectIcon: "Project icon"
        case .stone: "Stone"
        case .paper: "Paper"
        case .lemon: "Lemon"
        case .leaf: "Leaf"
        case .ink: "Ink"
        }
    }

    // A session that belongs to no project or workspace has no icon to borrow from, so
    // Project icon falls back to Stone, the quietest of the fixed colours.
    @MainActor
    func style(projectTint: Theme.ProjectTint?) -> UserMessageStyle {
        switch self {
        case .projectIcon: projectTint.map { UserMessageStyle.tinted($0.colour) } ?? .stone
        case .stone: UserMessageStyle.stone
        case .paper: UserMessageStyle.paper
        case .lemon: UserMessageStyle.lemon
        case .leaf: UserMessageStyle.leaf
        case .ink: UserMessageStyle.ink
        }
    }
}

struct UserMessageStyle: Equatable {
    let fill: Color
    let ring: Color
    // Ink is dark on a light page and light on a dark one, so what sits inside it is drawn
    // in the other appearance. That flips the AppKit text views too, not just SwiftUI text.
    var inverts = false
    // A bar down the writer's side in the project's colour. The bubble itself stays
    // Stone, since a whole bubble washed in the colour looked muddy on the page.
    var edge: Color?

    static let stone = UserMessageStyle(
        fill: Theme.adaptive(light: srgb(0.918, 0.902, 0.859), dark: srgb(0.153, 0.149, 0.137)),
        ring: Theme.adaptive(light: srgb(0.459, 0.420, 0.341, alpha: 0.14),
                             dark: srgb(1, 1, 1, alpha: 0.07)))
    static let paper = UserMessageStyle(
        fill: Theme.card,
        ring: Theme.adaptive(light: srgb(0.459, 0.420, 0.341, alpha: 0.22),
                             dark: srgb(1, 1, 1, alpha: 0.11)))
    // The brand yellow taken down to a wash.
    static let lemon = UserMessageStyle(
        fill: Theme.adaptive(light: srgb(0.953, 0.953, 0.831), dark: srgb(0.165, 0.169, 0.098)),
        ring: Theme.adaptive(light: srgb(0.667, 0.675, 0.157, alpha: 0.32),
                             dark: srgb(0.867, 0.878, 0.282, alpha: 0.16)))
    static let leaf = UserMessageStyle(fill: Theme.userMessage, ring: Theme.userMessageRing)
    static let ink = UserMessageStyle(
        fill: Theme.adaptive(light: srgb(0.169, 0.173, 0.149), dark: srgb(0.894, 0.882, 0.835)),
        ring: .clear,
        inverts: true)

    // Stone with the project's colour as an edge.
    // Built once per colour: the transcript compares styles to decide what to redraw, and
    // a fresh dynamic colour never equals the last one.
    @MainActor
    static func tinted(_ colour: Color) -> UserMessageStyle {
        if let style = tintedCache[colour] { return style }
        let style = UserMessageStyle(fill: stone.fill, ring: stone.ring, edge: edgeColour(colour))
        tintedCache[colour] = style
        return style
    }

    // Only the hue comes from the project colour. Lightness and chroma are fixed, so a
    // near-black Planets icon and a pastel Stripes one give bars of the same strength,
    // and none of them washes out to grey.
    static func edgeColour(_ colour: Color) -> Color {
        let hue = OKLCH(NSColor(colour))?.hue ?? 0
        return Theme.adaptive(
            light: OKLCH(lightness: 0.60, chroma: 0.14, hue: hue).nsColor(),
            dark: OKLCH(lightness: 0.72, chroma: 0.13, hue: hue).nsColor())
    }

    @MainActor private static var tintedCache: [Color: UserMessageStyle] = [:]

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                             alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension AppSettings {
    // The same colour the session's project or workspace wears in the sidebar, so a
    // bubble and the icon it belongs to always agree.
    @MainActor
    func userMessageStyle(for session: ChatSession, in store: ProjectStore) -> UserMessageStyle {
        guard messageColour == .projectIcon else { return messageColour.style(projectTint: nil) }
        let tint: Theme.ProjectTint? =
            if let workspace = session.workspaceID.flatMap(store.workspace) {
                workspace.sidebarAvatar.identityTint(
                    iconSet: sidebarIconSet, style: diceBearAvatarStyle,
                    name: workspace.name, monogramTint: Theme.workspaceTint)
            } else if let project = store.project(session.projectID) {
                project.sidebarAvatar.identityTint(
                    iconSet: sidebarIconSet, style: diceBearAvatarStyle,
                    name: project.name, monogramTint: Theme.projectTint(for: project.name))
            } else {
                nil
            }
        return messageColour.style(projectTint: tint)
    }
}
