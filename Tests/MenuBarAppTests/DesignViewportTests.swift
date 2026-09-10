import AppKit
import Testing
import WebKit
@testable import MenuBarApp

struct DesignViewportTests {
    @Test func theWholeArtboardFitsAndStaysCenteredOnResize() {
        var viewport = DesignViewport()
        let artboard = CGSize(width: 1440, height: 900)
        viewport.resize(to: CGSize(width: 960, height: 800), contentSize: artboard)
        #expect(viewport.scale == 2.0 / 3)
        #expect(viewport.contentFrame == CGRect(x: 0, y: 100, width: 960, height: 600))

        viewport.resize(to: CGSize(width: 480, height: 700), contentSize: artboard)
        #expect(viewport.contentFrame == CGRect(x: 0, y: 200, width: 480, height: 300))

        viewport.resize(to: CGSize(width: 1800, height: 600), contentSize: artboard)
        #expect(viewport.contentFrame == CGRect(x: 420, y: 0, width: 960, height: 600))
    }

    @Test func zoomKeepsTheSameDesignPointUnderThePointer() {
        var viewport = DesignViewport()
        viewport.resize(to: CGSize(width: 720, height: 600),
                        contentSize: CGSize(width: 1440, height: 900))
        let pointer = CGPoint(x: 500, y: 300)
        let designPoint = CGPoint(x: (pointer.x - viewport.origin.x) / viewport.scale,
                                  y: (pointer.y - viewport.origin.y) / viewport.scale)
        viewport.zoom(by: 2, at: pointer)
        #expect(viewport.scale == 1)
        #expect(viewport.origin.x + designPoint.x * viewport.scale == pointer.x)
        #expect(viewport.origin.y + designPoint.y * viewport.scale == pointer.y)
        #expect(!viewport.isFitted)

        viewport.zoom(by: 0.5, at: pointer)
        #expect(viewport.contentFrame == CGRect(x: 0, y: 75, width: 720, height: 450))
    }

    @Test func manualNavigationSurvivesResizeAndFitRestoresTheWholeDesign() {
        var viewport = DesignViewport()
        let artboard = CGSize(width: 1440, height: 900)
        viewport.resize(to: CGSize(width: 720, height: 600), contentSize: artboard)
        viewport.zoom(by: 2, at: CGPoint(x: 360, y: 300))
        viewport.pan(by: CGSize(width: 80, height: 40))
        let origin = viewport.origin
        viewport.resize(to: CGSize(width: 920, height: 700), contentSize: artboard)
        #expect(viewport.scale == 1)
        #expect(viewport.origin == CGPoint(x: origin.x + 100, y: origin.y + 50))
        viewport.pan(by: CGSize(width: 100_000, height: -100_000))
        #expect(viewport.contentFrame.intersection(CGRect(origin: .zero, size: viewport.size)).width >= 48)
        #expect(viewport.contentFrame.intersection(CGRect(origin: .zero, size: viewport.size)).height >= 48)
        viewport.fit()
        #expect(viewport.isFitted)
        #expect(abs(viewport.contentFrame.minX) < 0.001)
        #expect(abs(viewport.contentFrame.width - 920) < 0.001)
    }

    @Test func zoomLimitsStillAllowVeryLargeArtboardsToFit() {
        var viewport = DesignViewport()
        viewport.resize(to: CGSize(width: 320, height: 200),
                        contentSize: CGSize(width: 10_000, height: 10_000))
        #expect(viewport.scale == 0.02)
        viewport.zoom(by: 0.001, at: CGPoint(x: 160, y: 100))
        #expect(viewport.scale == 0.02)
        viewport.zoom(by: 100_000, at: CGPoint(x: 160, y: 100))
        #expect(viewport.scale == 4)
    }
}

@MainActor
@Suite(.serialized)
struct DesignWebViewportTests {
    @MainActor
    private final class Pane {
        let coordinator = DesignWebContent.Coordinator()
        let view: DesignCanvasViewport
        let window: NSWindow
        var webView: WKWebView { view.webView }

        init(screen: DesignScreen? = DesignScreen(id: "test", title: "Test", path: "index.html",
                                                 width: 1440, height: 900)) {
            view = DesignWebContent.makeViewport(coordinator: coordinator)
            view.frame = CGRect(x: 0, y: 0, width: 720, height: 600)
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = view
            view.configure(screen: screen, reset: true)
            view.layoutSubtreeIfNeeded()
        }

        func close() {
            DesignWebContent.dismantleNSView(view, coordinator: coordinator)
            window.contentView = nil
        }

        func load(_ html: String, from directory: URL? = nil) async throws {
            if let directory {
                let url = directory.appendingPathComponent("index.html")
                try html.write(to: url, atomically: true, encoding: .utf8)
                coordinator.readAccessURL = directory
                webView.loadFileURL(url, allowingReadAccessTo: directory)
            } else {
                webView.loadHTMLString(html, baseURL: nil)
            }
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                if !webView.isLoading,
                   (try? await webView.evaluateJavaScript(
                    "typeof window.__codeStationSetSelection === 'function'")) as? Bool == true {
                    view.layoutSubtreeIfNeeded()
                    return
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            Issue.record("Design web content did not finish loading")
        }

        func settle() async throws {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(30))
                view.layoutSubtreeIfNeeded()
            }
        }
    }

    private let html = """
        <!doctype html><html><head><style>
        html, body { margin: 0; width: 1440px; height: 900px; overflow: hidden; }
        #target { position: absolute; left: 1100px; top: 650px; width: 200px; height: 80px; }
        </style></head><body><button id="target" onclick="window.clicks++">Toggle</button>
        <input id="field"><script>window.clicks = 0;</script></body></html>
        """

    @Test func fixedPageFitsWithoutChangingItsCSSLayoutWidth() async throws {
        let pane = Pane()
        defer { pane.close() }
        try await pane.load(html)
        #expect(pane.view.viewport.scale == 0.5)
        #expect(pane.view.convert(pane.webView.bounds, from: pane.webView)
                == CGRect(x: 0, y: 75, width: 720, height: 450))
        #expect(try await pane.webView.evaluateJavaScript("window.innerWidth") as? Int == 1440)

        pane.view.zoom(by: 2, at: CGPoint(x: 400, y: 300))
        try await pane.settle()
        #expect(try await pane.webView.evaluateJavaScript("window.innerWidth") as? Int == 1440)
        #expect(pane.webView.pageZoom == 1)

        pane.view.frame.size = CGSize(width: 360, height: 600)
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.view.viewport.scale == 1)
        pane.view.fit()
        try await pane.settle()
        #expect(pane.view.viewport.scale == 0.25)
        #expect(try await pane.webView.evaluateJavaScript("window.innerWidth") as? Int == 1440)
    }

    @Test func fixedPageWithoutAManifestIsMeasuredAndFitted() async throws {
        let pane = Pane(screen: nil)
        let scratch = ScratchDirectory()
        defer { pane.close() }
        try await pane.load(html, from: scratch.url)
        try await pane.settle()
        #expect(pane.view.viewport.contentSize == CGSize(width: 1440, height: 900))
        #expect(pane.view.viewport.scale == 0.5)
        #expect(pane.view.convert(pane.webView.bounds, from: pane.webView)
                == CGRect(x: 0, y: 75, width: 720, height: 450))

        let smaller = html.replacingOccurrences(of: "1440px", with: "1000px")
            .replacingOccurrences(of: "900px", with: "700px")
            .replacingOccurrences(of: "1100px", with: "700px")
            .replacingOccurrences(of: "650px", with: "450px")
        try await pane.load(smaller, from: scratch.url)
        try await pane.settle()
        #expect(pane.view.viewport.contentSize == CGSize(width: 1000, height: 700))
        #expect(pane.view.viewport.isFitted)
    }

    @Test func zoomingOutPreservesTextSizeAndWrappingWithinTheArtboard() async throws {
        let pane = Pane()
        defer { pane.close() }
        try await pane.load("""
            <!doctype html><style>
            html, body { margin: 0; width: 1440px; height: 900px; overflow: hidden; }
            body { font: 13.5px/1.5 -apple-system, sans-serif; }
            p { width: 600px; margin: 0; }
            </style><p id="copy">Change the export conversation to generate a PDF instead
            of the Markdown file. Keep the same file naming, and make sure code blocks
            do not break across pages.</p>
            """)
        pane.view.zoom(by: 2, at: CGPoint(x: 360, y: 300))
        try await pane.settle()
        let metrics = """
            (() => {
              const copy = document.getElementById('copy');
              return {width: window.innerWidth, height: window.innerHeight,
                textHeight: copy.getBoundingClientRect().height,
                fontSize: parseFloat(getComputedStyle(copy).fontSize)};
            })()
            """
        let original = try #require(try await pane.webView.evaluateJavaScript(metrics) as? [String: Double])
        for scale: CGFloat in [0.65, 0.17, 0.1, 4, 1] {
            pane.view.zoom(by: scale / pane.view.viewport.scale, at: CGPoint(x: 360, y: 300))
            try await pane.settle()
            let displayed = pane.view.convert(pane.webView.bounds, from: pane.webView)
            #expect(abs(displayed.width - 1440 * scale) < 0.001)
            #expect(abs(displayed.height - 900 * scale) < 0.001)
            let zoomed = try #require(try await pane.webView.evaluateJavaScript(metrics) as? [String: Double])
            for (key, value) in original {
                let actual = try #require(zoomed[key])
                #expect(abs(actual - value) < 2, "\(key) changed at \(scale) zoom: \(original) -> \(zoomed)")
            }
        }
    }

    @Test func responsivePageFollowsThePaneWhileZoomPreservesItsLayout() async throws {
        let pane = Pane(screen: nil)
        defer { pane.close() }
        try await pane.load("<!doctype html><style>body { margin: 0 }</style><p>Responsive</p>")
        pane.view.zoom(by: 1.5, at: CGPoint(x: 360, y: 300))
        try await pane.settle()
        #expect(try await pane.webView.evaluateJavaScript("window.innerWidth") as? Int == 720)
        pane.view.frame.size = CGSize(width: 480, height: 600)
        try await pane.settle()
        #expect(pane.view.viewport.scale == 1.5)
        #expect(try await pane.webView.evaluateJavaScript("window.innerWidth") as? Int == 480)
    }

    @Test func dragPansWithoutClickingAndARegularClickStillWorks() async throws {
        let pane = Pane()
        defer { pane.close() }
        try await pane.load(html)
        let origin = pane.view.viewport.origin
        _ = try await pane.webView.evaluateJavaScript("""
            (() => {
              const target = document.getElementById('target');
              const mouse = (type, x, y, buttons) => target.dispatchEvent(new MouseEvent(type,
                {bubbles: true, cancelable: true, screenX: x, screenY: y, button: 0, buttons}));
              mouse('mousedown', 100, 100, 1);
              mouse('mousemove', 160, 140, 1);
              mouse('mouseup', 160, 140, 0);
              mouse('click', 160, 140, 0);
            })();
            """)
        try await pane.settle()
        #expect(pane.view.viewport.origin == CGPoint(x: origin.x + 60, y: origin.y + 40))
        #expect(try await pane.webView.evaluateJavaScript("window.clicks") as? Int == 0)
        _ = try await pane.webView.evaluateJavaScript("document.getElementById('target').click()")
        #expect(try await pane.webView.evaluateJavaScript("window.clicks") as? Int == 1)
    }

    @Test(arguments: [0.5, 0.17, 2.0])
    func selectingAnElementUsesArtboardSnapshotCoordinatesAndDoesNotPan(scale: Double) async throws {
        let pane = Pane()
        defer { pane.close() }
        var selection: DesignElementSelection?
        pane.coordinator.onSelection = { selection = $0 }
        try await pane.load(html)
        pane.view.zoom(by: scale / pane.view.viewport.scale, at: CGPoint(x: 360, y: 300))
        try await pane.settle()
        let viewport = pane.view.viewport
        pane.coordinator.setSelection(true, in: pane.webView)
        _ = try await pane.webView.evaluateJavaScript("""
            (() => {
              const target = document.getElementById('target');
              target.style.appearance = 'none';
              target.style.background = '#ff0000';
              target.style.color = '#ff0000';
              target.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, buttons: 1, screenX: 100}));
              target.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, buttons: 1, screenX: 200}));
              target.click();
            })();
            """)
        try await pane.settle()
        #expect(pane.view.viewport == viewport)
        #expect(selection?.selector == "#target")
        #expect(selection?.rect == CGRect(x: 1100, y: 650, width: 200, height: 80))
        #expect(try await pane.webView.evaluateJavaScript("window.clicks") as? Int == 0)

        let request = DesignSnapshotRequest(purpose: .selection, rect: try #require(selection).rect)
        let snapshot: NSImage? = await withCheckedContinuation { continuation in
            pane.coordinator.onSnapshot = { image, _ in continuation.resume(returning: image) }
            pane.coordinator.takeSnapshot(request, of: pane.webView)
        }
        let image = try #require(snapshot)
        #expect(image.size == CGSize(width: 200, height: 80))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.9)
        #expect(center.greenComponent < 0.25)
        #expect(center.blueComponent < 0.25)
    }
}
