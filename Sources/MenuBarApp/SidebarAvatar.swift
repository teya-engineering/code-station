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
                switch motion {
                case .still:
                    Image(nsImage: artwork.image)
                        .interpolation(.high)
                        .resizable()
                        .scaledToFill()
                case .animated:
                    AnimatedDiceBearImage(key: artwork.key, data: artwork.data)
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
    let data: Data
    let image: NSImage
}

@MainActor
private enum SidebarAvatarArt {
    private static var cache: [String: SidebarAvatarArtwork] = [:]

    static func artwork(for avatar: SidebarAvatar,
                        style: DiceBearAvatarStyle) -> SidebarAvatarArtwork? {
        guard let url = avatar.artworkURL(style: style) else { return nil }
        let key = url.path
        if let artwork = cache[key] { return artwork }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        let artwork = SidebarAvatarArtwork(key: key, data: data, image: image)
        cache[key] = artwork
        return artwork
    }
}

private struct AnimatedDiceBearImage: NSViewRepresentable {
    let key: String
    let data: Data

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
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        let source = data.base64EncodedString()
        webView.loadHTMLString("""
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <meta http-equiv="Content-Security-Policy"
                    content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
              <style>
                html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
                img { display: block; width: 100%; height: 100%; object-fit: cover; }
              </style>
            </head>
            <body><img src="data:image/svg+xml;base64,\(source)" alt=""></body>
            </html>
            """, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
    }

    final class Coordinator {
        var loadedKey: String?
    }
}
