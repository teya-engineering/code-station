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

    var seed: String { "\(subject.rawValue)-\(id.uuidString.lowercased())" }

    func artworkIndex(count: Int = artworkCount) -> Int? {
        Self.artworkIndex(seed: seed, count: count)
    }

    func artworkURL(style: DiceBearAvatarStyle,
                    bundle: Bundle = AppResources.bundle) -> URL? {
        guard let index = artworkIndex() else { return nil }
        return Self.artworkURL(style: style, index: index, bundle: bundle)
    }

    @MainActor
    func primaryColour(style: DiceBearAvatarStyle) -> Color? {
        SidebarAvatarArt.artwork(for: self, style: style)?.primaryColour
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
                DiceBearAvatarImage(
                    key: artwork.key,
                    source: artwork.source,
                    motion: motion)
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

    let avatar: SidebarAvatar
    let name: String
    let tint: Theme.ProjectTint
    var dashed = false
    var stacked = false

    var body: some View {
        switch appSettings.sidebarIconSet {
        case .monograms:
            fallback
        case .diceBear:
            DiceBearAvatarView(
                avatar: avatar,
                style: appSettings.diceBearAvatarStyle,
                motion: appSettings.sidebarIconMotion,
                side: 26) {
                    fallback
                }
        }
    }

    private var fallback: some View {
        ProjectTileView(name: name, tint: tint, dashed: dashed, stacked: stacked)
    }
}

private struct SidebarAvatarArtwork {
    let key: String
    let source: String
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
            primaryColour: style.primaryColour(in: source)?.colour)
        cache[key] = artwork
        return artwork
    }
}

enum DiceBearAvatarDocument {
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

private struct DiceBearAvatarImage: NSViewRepresentable {
    let key: String
    let source: String
    let motion: SidebarIconMotion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.setAccessibilityElement(false)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let configuration = Configuration(key: key, motion: motion)
        guard context.coordinator.loadedConfiguration != configuration else { return }
        context.coordinator.loadedConfiguration = configuration

        webView.loadHTMLString(
            DiceBearAvatarDocument.html(source: source, motion: motion),
            baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
    }

    struct Configuration: Equatable {
        let key: String
        let motion: SidebarIconMotion
    }

    final class Coordinator {
        var loadedConfiguration: Configuration?
    }
}
