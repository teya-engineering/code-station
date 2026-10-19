import AppKit
import Foundation
import WebKit
import CodeStationCore

// The pictures a design second opinion is shown. Drawing a screen takes a web view, so
// this half of DesignSecondOpinion lives in the GUI and is handed to the store.
extension DesignSecondOpinion {
    // Each screen drawn at its own size, light and then dark, by a web view that is never
    // shown. A page taller than its screen is drawn whole, up to a limit.
    @MainActor
    static func capture(_ screens: [DesignScreen], in directory: URL, to folder: URL) async -> [Shot] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shots: [Shot] = []
        for screen in screens {
            guard let url = DesignManifest.safeURL(for: screen, in: directory) else { continue }
            let width = CGFloat(screen.width ?? 1280)
            let height = CGFloat(screen.height ?? 800)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                    configuration: configuration)
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = webView
            defer { window.contentView = nil }
            webView.appearance = NSAppearance(named: .aqua)
            webView.loadFileURL(url, allowingReadAccessTo: directory)
            guard await loaded(webView) else { continue }
            if let full = try? await webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") as? Double,
               full > height {
                webView.setFrameSize(CGSize(width: width, height: min(full, 6000)))
                try? await Task.sleep(for: .milliseconds(120))
            }
            let stem = folder.appendingPathComponent(fileStem(screen.id)).path
            guard let light = await picture(of: webView, width: width) else { continue }
            let lightPath = stem + "-light.png"
            guard (try? light.write(to: URL(fileURLWithPath: lightPath))) != nil else { continue }
            webView.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(250))
            var darkPath: String?
            if let dark = await picture(of: webView, width: width), dark != light,
               (try? dark.write(to: URL(fileURLWithPath: stem + "-dark.png"))) != nil {
                darkPath = stem + "-dark.png"
            }
            shots.append(Shot(screen: screen, light: lightPath, dark: darkPath))
        }
        return shots
    }

    private static func fileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return stem.isEmpty ? "screen" : stem
    }

    @MainActor
    private static func loaded(_ webView: WKWebView) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                // Web fonts and images settle a moment after the document says it is done.
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private static func picture(of webView: WKWebView, width: CGFloat) async -> Data? {
        let configuration = WKSnapshotConfiguration()
        // One image pixel to one CSS pixel, so a box a reviewer gives lands on the page.
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return nil }
        // The snapshot comes back at the screen's backing scale, so it is drawn again at
        // one pixel per CSS pixel.
        let size = CGSize(width: width, height: (image.size.height * width / max(image.size.width, 1)).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

}
