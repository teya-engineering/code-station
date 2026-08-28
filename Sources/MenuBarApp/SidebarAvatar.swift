import AppKit
import SwiftUI
import WebKit

struct SidebarAvatar: Equatable, Sendable {
    static let artworkCount = 64
    static let preview = SidebarAvatar(
        subject: .project,
        id: UUID(uuidString: "C0DEC0DE-C0DE-C0DE-C0DE-C0DEC0DEC0DE")!)

    enum Subject: String, Sendable {
        case project
        case task
        case workspace
    }

    let subject: Subject
    let id: UUID
    let chosenArtworkIndex: Int?

    init(subject: Subject, id: UUID, artworkIndex: Int? = nil) {
        self.subject = subject
        self.id = id
        chosenArtworkIndex = artworkIndex
    }

    var seed: String { "\(subject.rawValue)-\(id.uuidString.lowercased())" }

    func artworkIndex(count: Int = artworkCount) -> Int? {
        if let chosenArtworkIndex, (1...count).contains(chosenArtworkIndex) {
            return chosenArtworkIndex
        }
        return Self.artworkIndex(seed: seed, count: count)
    }

    func randomArtworkIndex(count: Int = artworkCount) -> Int? {
        guard count > 1, let current = artworkIndex(count: count) else { return nil }
        let offset = Int.random(in: 1..<count)
        return ((current - 1 + offset) % count) + 1
    }

    func artworkURL(style: DiceBearAvatarStyle,
                    bundle: Bundle = AppResources.bundle) -> URL? {
        guard let index = artworkIndex() else { return nil }
        return Self.artworkURL(style: style, index: index, bundle: bundle)
    }

    func motion(sessions: [ChatSession], isBusy: (UUID) -> Bool) -> SidebarIconMotion {
        let active = sessions.contains { session in
            let belongsToAvatar = switch subject {
            case .project, .task:
                session.workspaceID == nil && session.projectID == id
            case .workspace:
                session.workspaceID == id
            }
            return belongsToAvatar && isBusy(session.id)
        }
        return active ? .animated : .still
    }

    @MainActor
    func primaryColour(style: DiceBearAvatarStyle) -> Color? {
        SidebarAvatarArt.artwork(for: self, style: style)?.primaryColour
    }

    @MainActor
    func artworkImage(style: DiceBearAvatarStyle) -> NSImage? {
        SidebarAvatarArt.artwork(for: self, style: style)?.image
    }

    static func artworkIndex(seed: String, count: Int = artworkCount) -> Int? {
        guard count > 0 else { return nil }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count)) + 1
    }

    static func artworkURL(style: DiceBearAvatarStyle, index: Int,
                           bundle: Bundle = AppResources.bundle) -> URL? {
        guard (1...artworkCount).contains(index) else { return nil }
        return bundle.url(
            forResource: String(format: "sidebar-avatar-%@-%02d", style.rawValue, index),
            withExtension: "svg")
    }
}

extension Project {
    var sidebarAvatar: SidebarAvatar {
        SidebarAvatar(
            subject: kind == .adHoc ? .task : .project,
            id: id,
            artworkIndex: sidebarAvatarIndex)
    }
}

extension ProjectWorkspace {
    var sidebarAvatar: SidebarAvatar {
        SidebarAvatar(subject: .workspace, id: id, artworkIndex: sidebarAvatarIndex)
    }
}

struct DiceBearAvatarView<Placeholder: View>: View {
    let avatar: SidebarAvatar
    let style: DiceBearAvatarStyle
    let motion: SidebarIconMotion
    let side: CGFloat
    @ViewBuilder let placeholder: Placeholder

    init(avatar: SidebarAvatar, style: DiceBearAvatarStyle,
         motion: SidebarIconMotion, side: CGFloat,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.avatar = avatar
        self.style = style
        self.motion = motion
        self.side = side
        self.placeholder = placeholder()
    }

    var body: some View {
        ZStack {
            placeholder
            if let artwork = SidebarAvatarArt.artwork(for: avatar, style: style) {
                if style.usesWebAnimation(for: motion) {
                    AnimatedDiceBearAvatarImage(key: artwork.key, source: artwork.source)
                } else if let image = artwork.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.27))
        .overlay(RoundedRectangle(cornerRadius: side * 0.27).stroke(Theme.border))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SidebarIdentityTile: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    let avatar: SidebarAvatar
    let name: String
    let tint: Theme.ProjectTint
    var dashed = false
    var stacked = false
    // The rail draws these at one size; a preview of the icon style borrows the same tile
    // at whatever size the preview has room for.
    var side: CGFloat = 26

    var body: some View {
        switch appSettings.sidebarIconSet {
        case .monograms:
            fallback
                .modifier(StillArtworkActiveMotion(active: isActive))
        case .diceBear:
            DiceBearAvatarView(
                avatar: avatar,
                style: appSettings.diceBearAvatarStyle,
                motion: motion,
                side: side) {
                    fallback
                }
                .modifier(StillArtworkActiveMotion(
                    active: isActive && !appSettings.diceBearAvatarStyle.supportsAnimation))
        }
    }

    private var motion: SidebarIconMotion {
        avatar.motion(sessions: store.sidebarSessions) { runner.state($0).isBusy }
    }

    private var isActive: Bool {
        motion == .animated
    }

    private var fallback: some View {
        ProjectTileView(name: name, tint: tint, side: side, dashed: dashed, stacked: stacked)
    }
}

private struct StillArtworkActiveMotion: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed && !reduceMotion ? 0.55 : 1)
            .animation(active && !reduceMotion
                       ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                       : nil,
                       value: dimmed)
            .onAppear { dimmed = active }
            .onChange(of: active) { _, running in dimmed = running }
    }
}

private struct SidebarAvatarArtwork {
    let key: String
    let source: String
    let image: NSImage?
    let primaryColour: Color?
}

struct SidebarAvatarPrimaryColour: Equatable, Sendable {
    private static let backgroundMarker = #"<rect width="100" height="100" fill=""#

    let rgb: UInt32

    init?(svg: String) {
        guard let marker = svg.range(of: Self.backgroundMarker, options: .backwards),
              let end = svg.index(marker.upperBound, offsetBy: 7, limitedBy: svg.endIndex) else {
            return nil
        }
        let value = svg[marker.upperBound..<end]
        guard value.first == "#", let rgb = UInt32(value.dropFirst(), radix: 16) else {
            return nil
        }
        self.rgb = rgb
    }

    var colour: Color {
        Color(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255)
    }
}

extension DiceBearAvatarStyle {
    func usesWebAnimation(for motion: SidebarIconMotion) -> Bool {
        motion == .animated && supportsAnimation
    }

    func primaryColour(in svg: String) -> SidebarAvatarPrimaryColour? {
        guard usesArtworkPrimaryColour else { return nil }
        // These styles put their identity colour on the full-bleed background. Shapes
        // and Landscape use several peers, so neither has one colour to claim as primary.
        return SidebarAvatarPrimaryColour(svg: svg)
    }
}

@MainActor
private enum SidebarAvatarArt {
    private static var cache: [String: SidebarAvatarArtwork] = [:]

    static func artwork(for avatar: SidebarAvatar,
                        style: DiceBearAvatarStyle) -> SidebarAvatarArtwork? {
        guard let url = avatar.artworkURL(style: style) else { return nil }
        let key = url.path
        if let artwork = cache[key] { return artwork }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let artwork = SidebarAvatarArtwork(
            key: key,
            source: source,
            image: DiceBearAvatarDocument.stillImage(source: source),
            primaryColour: style.primaryColour(in: source)?.colour)
        cache[key] = artwork
        return artwork
    }
}

enum DiceBearAvatarDocument {
    static func stillImage(source: String) -> NSImage? {
        guard let source = sourceWithInlinedUses(source) else { return nil }
        return NSImage(data: Data(source.utf8))
    }

    // AppKit's SVG renderer ignores referenced layers. Inline them once before the
    // result enters the artwork cache so static avatars keep the complete design.
    private static func sourceWithInlinedUses(_ source: String) -> String? {
        guard let document = try? XMLDocument(xmlString: source),
              let root = document.rootElement(),
              let nodes = try? document.nodes(forXPath: "//*[@id]") else {
            return nil
        }

        var definitions: [String: XMLElement] = [:]
        for case let element as XMLElement in nodes {
            if let id = element.attribute(forName: "id")?.stringValue {
                definitions[id] = element
            }
        }
        guard inlineUses(in: root, definitions: definitions, resolving: []) else {
            return nil
        }
        return document.xmlString
    }

    private static func inlineUses(in element: XMLElement,
                                   definitions: [String: XMLElement],
                                   resolving: Set<String>) -> Bool {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if child.name == "use" {
                guard let replacement = replacement(
                    for: child,
                    definitions: definitions,
                    resolving: resolving),
                    let index = element.children?.firstIndex(where: { $0 === child }) else {
                    return false
                }
                child.detach()
                element.insertChild(replacement, at: index)
            } else if !inlineUses(
                in: child,
                definitions: definitions,
                resolving: resolving) {
                return false
            }
        }
        return true
    }

    private static func replacement(for use: XMLElement,
                                    definitions: [String: XMLElement],
                                    resolving: Set<String>) -> XMLElement? {
        guard let href = use.attribute(forName: "href")?.stringValue,
              href.hasPrefix("#") else {
            return nil
        }
        let id = String(href.dropFirst())
        guard !resolving.contains(id),
              let definition = definitions[id],
              let clone = definition.copy() as? XMLElement else {
            return nil
        }
        clone.removeAttribute(forName: "id")
        guard inlineUses(
            in: clone,
            definitions: definitions,
            resolving: resolving.union([id])) else {
            return nil
        }

        let replacement = XMLElement(name: "g")
        var transforms: [String] = []
        let x = use.attribute(forName: "x")?.stringValue
        let y = use.attribute(forName: "y")?.stringValue
        if x != nil || y != nil {
            transforms.append("translate(\(x ?? "0") \(y ?? "0"))")
        }
        if let transform = use.attribute(forName: "transform")?.stringValue {
            transforms.append(transform)
        }
        if !transforms.isEmpty {
            replacement.addAttribute(XMLNode.attribute(
                withName: "transform",
                stringValue: transforms.joined(separator: " ")) as! XMLNode)
        }
        for attribute in use.attributes ?? [] {
            guard let name = attribute.name,
                  !["href", "x", "y", "transform"].contains(name),
                  let copy = attribute.copy() as? XMLNode else {
                continue
            }
            replacement.addAttribute(copy)
        }
        replacement.addChild(clone)
        return replacement
    }

    static func html(source: String, motion: SidebarIconMotion) -> String {
        let motionStyle = switch motion {
        case .still:
            "* { animation: none !important; }"
        case .animated:
            """
            svg {
              --dbsq-t: 0.3 !important;
              --dbpa-t: 0.2 !important;
              --dbsh-t: 0.25 !important;
              --dbba-t: 0.3 !important;
              --dbwa-t: 0.25 !important;
              --dbsp-t: 0.55 !important;
              --dbla-t: 0.2 !important;
            }
            """
        }

        return """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <meta http-equiv="Content-Security-Policy"
                    content="default-src 'none'; style-src 'unsafe-inline'">
              <style>
                html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
                svg { display: block; width: 100%; height: 100%; }
                \(motionStyle)
              </style>
            </head>
            <body>\(source)</body>
            </html>
            """
    }
}

private struct AnimatedDiceBearAvatarImage: NSViewRepresentable {
    let key: String
    let source: String

    func makeNSView(context: Context) -> AnimatedAvatarWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = AnimatedAvatarWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.setAccessibilityElement(false)
        return webView
    }

    func updateNSView(_ webView: AnimatedAvatarWebView, context: Context) {
        webView.configure(key: key, source: source)
    }

    static func dismantleNSView(_ webView: AnimatedAvatarWebView, coordinator: ()) {
        webView.stop()
    }
}

@MainActor
private final class AnimatedAvatarWebView: WKWebView {
    private var artworkKey: String?
    private var source: String?
    private var animationRunning: Bool?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        refreshAnimation()
    }

    func configure(key: String, source: String) {
        guard artworkKey != key else { return }
        artworkKey = key
        self.source = source
        animationRunning = nil
        refreshAnimation()
    }

    func stop() {
        removeVisibilityObservations()
        stopLoading()
    }

    private func observeVisibility() {
        removeVisibilityObservations()
        let notifications = NotificationCenter.default
        if let window {
            notifications.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
            notifications.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didMiniaturizeNotification,
                object: window)
            notifications.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didDeminiaturizeNotification,
                object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            notifications.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: name,
                object: NSApp)
        }
    }

    private func removeVisibilityObservations() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func visibilityChanged() {
        refreshAnimation()
    }

    private func refreshAnimation() {
        guard let source, let window else { return }
        let shouldRun = window.occlusionState.contains(.visible)
            && !window.isMiniaturized
            && !NSApp.isHidden
        guard animationRunning != shouldRun else { return }
        animationRunning = shouldRun
        loadHTMLString(
            DiceBearAvatarDocument.html(
                source: source,
                motion: shouldRun ? .animated : .still),
            baseURL: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
