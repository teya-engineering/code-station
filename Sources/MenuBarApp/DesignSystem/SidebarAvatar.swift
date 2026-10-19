import AppKit
import SwiftUI
import WebKit
import CodeStationCore

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

    // Every artwork style gives its own colour, so the rail, the home view and a
    // person's messages all agree with the icon. Styles drawn in several colours over a
    // pale ground give the hue most of the tile is drawn in.
    @MainActor
    func identityTint(iconSet: SidebarIconSet, style: DiceBearAvatarStyle,
                      name: String, monogramTint: Theme.ProjectTint) -> Theme.ProjectTint {
        guard iconSet == .diceBear else { return monogramTint }
        guard let colour = primaryColour(style: style) else {
            return style.hasPrimaryColourBackground ? monogramTint : Theme.projectTint(for: name)
        }
        return Theme.ProjectTint(colour: colour, ink: colour)
    }

    @MainActor
    func artworkImage(style: DiceBearAvatarStyle) -> NSImage? {
        SidebarAvatarArt.artwork(for: self, style: style)?.image
    }

    static func artworkIndex(seed: String, count: Int = artworkCount) -> Int? {
        guard count > 0 else { return nil }
        return Int(StableHash.fnv1a(seed) % UInt64(count)) + 1
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

    // The still artwork stays under the animated one. A web view shows nothing until its
    // page has painted, which is a frame or more after a tile scrolls into view, and a
    // blank tile is what that gap looks like. The animated styles all draw a full-bleed
    // background, so the page hides the still copy completely once it is up.
    var body: some View {
        ZStack {
            placeholder
            if let artwork = SidebarAvatarArt.artwork(for: avatar, style: style) {
                if let image = artwork.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
                if style.usesWebAnimation(for: motion) {
                    AnimatedDiceBearAvatarImage(key: artwork.key, source: artwork.source)
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
    var pinned = false

    // The pin sits on the tile rather than after the name, so a long name keeps its full
    // width. It is decoration: the row says "Pinned" to VoiceOver itself.
    var body: some View {
        artwork
            .overlay(alignment: .bottomTrailing) {
                if pinned {
                    TilePinBadge()
                        .offset(x: 5, y: 4)
                }
            }
    }

    @ViewBuilder
    private var artwork: some View {
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

private struct TilePinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Theme.accentFill))
            .background(Circle().fill(Theme.sidebar).padding(-1.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// Artwork that cannot animate itself says a session is working by breathing instead.
private struct StillArtworkActiveMotion: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        Breathing(active: active) { content }
    }
}

private struct SidebarAvatarArtwork {
    let key: String
    let source: String
    let image: NSImage?
    let primaryColour: Color?
}

struct SidebarAvatarPrimaryColour: Equatable, Sendable {
    let rgb: UInt32

    init?(svg: String) {
        // The background fills the whole canvas, and the canvas is not the same size in
        // every style. The last match is the one the drawing sits on; earlier ones belong
        // to layers kept in the definitions block.
        let background = /<rect width="\d+" height="\d+" fill="#([0-9a-fA-F]{6})"/
        guard let match = svg.matches(of: background).last,
              let rgb = UInt32(match.1, radix: 16) else {
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

// Shapes, Landscape and Weave are drawn in several colours over a pale ground. Their main
// hue is the one that covers the most of the drawn tile, counting only pixels colourful
// enough to have a hue at all.
enum SidebarAvatarMainHue {
    static func colour(in image: NSImage) -> Color? {
        let side = 32
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let binCount = 24
        var area = [Int](repeating: 0, count: binCount)
        var hues = [[OKLCH]](repeating: [], count: binCount)
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5,
                      let colour = OKLCH(pixel), colour.chroma >= 0.04 else { continue }
                let bin = Int(colour.hue / 360 * Double(binCount)) % binCount
                area[bin] += 1
                hues[bin].append(colour)
            }
        }
        guard let main = area.indices.max(by: { area[$0] < area[$1] }), area[main] > 0 else {
            return nil
        }
        // Averaging on the a and b axes rather than the hue angle keeps a bin that
        // straddles 0 degrees from averaging out to the opposite side of the wheel.
        let pixels = hues[main]
        let okA = pixels.map { $0.chroma * cos($0.hue * .pi / 180) }.reduce(0, +)
        let okB = pixels.map { $0.chroma * sin($0.hue * .pi / 180) }.reduce(0, +)
        let count = Double(pixels.count)
        let average = OKLCH(
            lightness: pixels.map(\.lightness).reduce(0, +) / count,
            chroma: hypot(okA, okB) / count,
            hue: (atan2(okB, okA) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        return Color(nsColor: average.nsColor())
    }
}

extension DiceBearAvatarStyle {
    func usesWebAnimation(for motion: SidebarIconMotion) -> Bool {
        motion == .animated && supportsAnimation
    }

    func primaryColour(in svg: String) -> SidebarAvatarPrimaryColour? {
        guard hasPrimaryColourBackground else { return nil }
        // These styles put their identity colour on the full-bleed background. Shapes
        // and Landscape use several peers, so neither has one colour to claim as primary,
        // and Weave keeps its colour in the bands over a background too pale to tint with.
        // Those three are read from the drawn tile instead (see SidebarAvatarMainHue).
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
        let image = DiceBearAvatarDocument.stillImage(source: source)
        let artwork = SidebarAvatarArtwork(
            key: key,
            source: source,
            image: image,
            primaryColour: style.hasPrimaryColourBackground
                ? style.primaryColour(in: source)?.colour
                : image.flatMap(SidebarAvatarMainHue.colour(in:)))
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
              --dbcr-t: 0.55 !important;
              --dbmo-t: 0.55 !important;
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
                html, body { width: 100%; height: 100%; margin: 0; overflow: hidden;
                             background: transparent; }
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
        // WebKit paints a white base behind every page until told not to. The setter is
        // not public, so it is only called when this build of WebKit still has it.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
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

extension ProjectStore {
    func changeSidebarAvatar(forProject id: UUID) {
        guard let next = project(id)?.sidebarAvatar.randomArtworkIndex() else { return }
        setSidebarAvatarIndex(next, forProject: id)
    }

    func changeSidebarAvatar(forWorkspace id: UUID) {
        guard let next = workspace(id)?.sidebarAvatar.randomArtworkIndex() else { return }
        setSidebarAvatarIndex(next, forWorkspace: id)
    }
}
