import AppKit
import SwiftUI
import WebKit

struct DesignWebView: View {
    let url: URL
    let readAccessURL: URL
    let screen: DesignScreen?
    let revision: DesignArtifactRevision
    let reloadGeneration: Int
    let selectionEnabled: Bool
    let snapshotRequest: DesignSnapshotRequest?
    let onSelection: (DesignElementSelection) -> Void
    let onSnapshot: (NSImage?, DesignSnapshotRequest) -> Void
    var onViewport: ((Double) -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var fitGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            DesignWebContent(
                url: url, readAccessURL: readAccessURL, screen: screen,
                revision: revision, reloadGeneration: reloadGeneration,
                selectionEnabled: selectionEnabled, snapshotRequest: snapshotRequest,
                fitGeneration: fitGeneration,
                onSelection: onSelection, onSnapshot: onSnapshot,
                onViewport: onViewport, onScale: { scale = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("Scroll to zoom · Drag to pan")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .appTooltip("Mouse wheel to zoom. Drag to pan, or middle-drag over controls. "
                        + "On a trackpad, pinch to zoom and use two fingers to pan. "
                        + "Double-click the canvas background to fit.")
                Spacer(minLength: 0)
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Canvas zoom \(Int((scale * 100).rounded())) percent")
                Button { fitGeneration += 1 } label: {
                    Text("Fit")
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift()
                .accessibilityLabel("Fit design to canvas")
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.card)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }
}

struct DesignWebContent: NSViewRepresentable {
    let url: URL
    let readAccessURL: URL
    let screen: DesignScreen?
    let revision: DesignArtifactRevision
    let reloadGeneration: Int
    let selectionEnabled: Bool
    let snapshotRequest: DesignSnapshotRequest?
    let fitGeneration: Int
    let onSelection: (DesignElementSelection) -> Void
    let onSnapshot: (NSImage?, DesignSnapshotRequest) -> Void
    // The page reports its own width rather than the view reporting its frame.
    // `window.innerWidth` is the number the design's CSS is resolved against, so it stays
    // right whatever sits between the view's bounds and the layout viewport.
    var onViewport: ((Double) -> Void)? = nil
    var onScale: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DesignCanvasViewport {
        Self.makeViewport(coordinator: context.coordinator)
    }

    static func makeViewport(coordinator: Coordinator) -> DesignCanvasViewport {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.selectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        configuration.userContentController.add(
            coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .white
        webView.isInspectable = true
        let viewport = DesignCanvasViewport(webView: webView)
        coordinator.viewport = viewport
        viewport.onScale = { [weak coordinator] scale in
            Task { @MainActor in coordinator?.onScale?(scale) }
        }
        return viewport
    }

    func updateNSView(_ viewport: DesignCanvasViewport, context: Context) {
        let webView = viewport.webView
        context.coordinator.onSelection = onSelection
        context.coordinator.onSnapshot = onSnapshot
        context.coordinator.onViewport = onViewport
        context.coordinator.onScale = onScale
        context.coordinator.readAccessURL = readAccessURL
        context.coordinator.setSelection(selectionEnabled, in: webView)
        if context.coordinator.fitGeneration != fitGeneration {
            context.coordinator.fitGeneration = fitGeneration
            viewport.fit()
        }

        if let snapshotRequest,
           context.coordinator.snapshotID != snapshotRequest.id {
            context.coordinator.snapshotID = snapshotRequest.id
            context.coordinator.takeSnapshot(snapshotRequest, of: webView)
        }

        let fileKey = revision.files.map {
            "\($0.path):\($0.modified.timeIntervalSinceReferenceDate):\($0.size)"
        }.joined(separator: "|")
        let key = "\(url.path):\(fileKey):\(reloadGeneration)"
        guard context.coordinator.loadedKey != key else { return }
        let reset = context.coordinator.loadedURL != url
        context.coordinator.loadedURL = url
        context.coordinator.loadedKey = key
        context.coordinator.navigationPending = true
        viewport.configure(screen: screen, reset: reset)
        viewport.layoutSubtreeIfNeeded()
        webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    static func dismantleNSView(_ viewport: DesignCanvasViewport, coordinator: Coordinator) {
        viewport.stopMonitoring()
        let webView = viewport.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "codeStationDesignSelection"

        var loadedKey: String?
        var loadedURL: URL?
        var displayedURL: URL?
        var navigationPending = true
        var readAccessURL: URL?
        weak var viewport: DesignCanvasViewport?
        var fitGeneration = 0
        var snapshotID: UUID?
        var selectionEnabled = false
        var onSelection: ((DesignElementSelection) -> Void)?
        var onSnapshot: ((NSImage?, DesignSnapshotRequest) -> Void)?
        var onViewport: ((Double) -> Void)?
        var onScale: ((CGFloat) -> Void)?

        func setSelection(_ enabled: Bool, in webView: WKWebView) {
            guard selectionEnabled != enabled else { return }
            selectionEnabled = enabled
            webView.evaluateJavaScript("window.__codeStationSetSelection?.(\(enabled));")
        }

        func takeSnapshot(_ request: DesignSnapshotRequest, of webView: WKWebView) {
            let configuration = WKSnapshotConfiguration()
            if let rect = request.rect {
                let clipped = rect.intersection(webView.bounds)
                if !clipped.isNull, clipped.width > 1, clipped.height > 1 {
                    configuration.rect = clipped
                }
            }
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                self?.onSnapshot?(image, request)
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName,
                  let body = message.body as? [String: Any] else { return }

            if body["kind"] as? String == "viewport" {
                guard !navigationPending else { return }
                if let width = body["width"] as? Double { onViewport?(width) }
                if let width = body["contentWidth"] as? Double,
                   let height = body["contentHeight"] as? Double {
                    viewport?.measureContent(width: width, height: height)
                }
                return
            }

            if body["kind"] as? String == "pan" {
                if let x = body["x"] as? Double, let y = body["y"] as? Double {
                    viewport?.pan(by: CGSize(width: x, height: y))
                }
                return
            }
            if body["kind"] as? String == "fit" {
                viewport?.fit()
                return
            }

            guard let selector = body["selector"] as? String,
                  let tag = body["tag"] as? String,
                  let rect = body["rect"] as? [String: Any],
                  let x = rect["x"] as? Double,
                  let y = rect["y"] as? Double,
                  let width = rect["width"] as? Double,
                  let height = rect["height"] as? Double else { return }
            onSelection?(DesignElementSelection(
                selector: selector,
                tag: tag,
                text: (body["text"] as? String ?? "").trimmed,
                rect: CGRect(x: x, y: y, width: width, height: height)))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigationPending = false
            webView.evaluateJavaScript(
                "window.__codeStationSetSelection?.(\(selectionEnabled)); "
                    + "window.__codeStationReportViewport?.();")
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let allowed = ["file", "about", "data", "blob"].contains(scheme ?? "")
            let destination = navigationAction.request.url
            let sameDocument = destination?.fragment != nil
                && destination?.path == webView.url?.path
                && destination?.query == webView.url?.query
                && navigationAction.navigationType != .reload
            let loadsDocument = allowed && !sameDocument
                && navigationAction.targetFrame?.isMainFrame == true
            if loadsDocument {
                navigationPending = true
            }
            if scheme == "file", loadsDocument,
               let directory = readAccessURL, let url = navigationAction.request.url {
                let screen = DesignManifest.read(from: directory).screens.first {
                    DesignManifest.safeURL(for: $0, in: directory) == url
                }
                viewport?.configure(screen: screen, reset: displayedURL != url)
                viewport?.layoutSubtreeIfNeeded()
                displayedURL = url
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    private static let selectionScript = #"""
    (() => {
      var enabled = false;
      var highlighted = null;
      var previousOutline = "";
      var previousCursor = "";

      function clearHighlight() {
        if (!highlighted) return;
        highlighted.style.outline = previousOutline;
        highlighted.style.cursor = previousCursor;
        highlighted = null;
      }

      function highlight(element) {
        if (highlighted === element) return;
        clearHighlight();
        highlighted = element;
        previousOutline = element.style.outline;
        previousCursor = element.style.cursor;
        element.style.outline = "2px solid #00a86b";
        element.style.cursor = "crosshair";
      }

      function selectorFor(element) {
        if (element.id) return `#${CSS.escape(element.id)}`;
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.body) {
          let part = current.tagName.toLowerCase();
          const classes = Array.from(current.classList).filter(Boolean).slice(0, 2);
          if (classes.length) part += classes.map(value => `.${CSS.escape(value)}`).join("");
          const siblings = current.parentElement
            ? Array.from(current.parentElement.children).filter(item => item.tagName === current.tagName)
            : [];
          if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
          parts.unshift(part);
          current = current.parentElement;
        }
        return parts.join(" > ");
      }

      var reportedViewport = "";
      function reportViewport() {
        const width = window.innerWidth;
        const root = document.documentElement;
        const body = document.body;
        const contentWidth = Math.max(root.scrollWidth, body?.scrollWidth || 0,
          body?.getBoundingClientRect().right || 0);
        const contentHeight = Math.max(root.scrollHeight, body?.scrollHeight || 0,
          body?.getBoundingClientRect().bottom || 0);
        const key = `${width}:${contentWidth}:${contentHeight}`;
        if (key === reportedViewport || !width) return;
        reportedViewport = key;
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({
          kind: "viewport", width, contentWidth, contentHeight
        });
      }
      reportViewport();
      window.__codeStationReportViewport = () => {
        reportedViewport = "";
        reportViewport();
      };
      window.addEventListener("resize", reportViewport);
      window.addEventListener("load", reportViewport);
      new ResizeObserver(reportViewport).observe(document.documentElement);
      if (document.body) new ResizeObserver(reportViewport).observe(document.body);

      let drag = null;
      let suppressClick = false;
      let dragCursor = "";
      let dragUserSelect = "";
      function stopDrag() {
        if (drag?.active) {
          document.documentElement.style.cursor = dragCursor;
          document.documentElement.style.userSelect = dragUserSelect;
        }
        drag = null;
      }

      document.addEventListener("mousedown", event => {
        suppressClick = false;
        if (enabled || event.button !== 0) return;
        // Form editing and native drag controls own their drag gestures. A simple
        // click elsewhere still reaches the prototype, including custom controls.
        if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), '
            + '[draggable="true"], [role="slider"], [role="scrollbar"], canvas')) return;
        drag = {x: event.screenX, y: event.screenY, active: false};
      }, true);

      document.addEventListener("mousemove", event => {
        if (!drag) return;
        if (!(event.buttons & 1)) { stopDrag(); return; }
        const x = event.screenX - drag.x;
        const y = event.screenY - drag.y;
        if (!drag.active && Math.hypot(x, y) < 4) return;
        if (!drag.active) {
          drag.active = true;
          clearHighlight();
          dragCursor = document.documentElement.style.cursor;
          dragUserSelect = document.documentElement.style.userSelect;
          document.documentElement.style.cursor = "grabbing";
          document.documentElement.style.userSelect = "none";
          window.getSelection()?.removeAllRanges();
        }
        suppressClick = true;
        event.preventDefault();
        event.stopImmediatePropagation();
        drag.x = event.screenX;
        drag.y = event.screenY;
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({kind: "pan", x, y});
      }, true);

      document.addEventListener("mouseup", event => {
        if (drag?.active) {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
        stopDrag();
      }, true);
      document.addEventListener("dragstart", event => {
        if (drag) event.preventDefault();
      }, true);
      window.addEventListener("blur", stopDrag);
      document.addEventListener("click", event => {
        if (!suppressClick) return;
        suppressClick = false;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
      document.addEventListener("dblclick", event => {
        if (enabled || (event.target !== document.body && event.target !== document.documentElement)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({kind: "fit"});
      }, true);

      window.__codeStationSetSelection = value => {
        stopDrag();
        enabled = Boolean(value);
        document.documentElement.style.cursor = enabled ? "crosshair" : "";
        if (!enabled) clearHighlight();
      };

      document.addEventListener("mouseover", event => {
        if (enabled) highlight(event.target);
      }, true);

      document.addEventListener("click", event => {
        if (!enabled) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const element = event.target;
        const rect = element.getBoundingClientRect();
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({
          selector: selectorFor(element),
          tag: element.tagName.toLowerCase(),
          text: (element.innerText || element.getAttribute("aria-label") || "").trim().slice(0, 160),
          rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
        });
      }, true);
    })();
    """#
}
