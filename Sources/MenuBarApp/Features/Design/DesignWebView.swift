import AppKit
import SwiftUI
import WebKit
import CodeStationCore

struct DesignWebView: View {
    static let toolbarHeight: CGFloat = 28

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
    // A second opinion's notes on this screen, drawn as pins on the spots they are about.
    var pins: [DesignPin] = []
    var hotPin: String? = nil
    var onPin: ((String) -> Void)? = nil
    var onPinHover: ((String?) -> Void)? = nil

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
                onViewport: onViewport, onScale: { scale = $0 },
                pins: pins, hotPin: hotPin, onPin: onPin, onPinHover: onPinHover)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("Scroll to zoom · Drag to pan")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .appTooltip("Scrollable parts of the design scroll normally. Elsewhere, use the mouse wheel to zoom. "
                        + "Drag to pan, or middle-drag over controls. "
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
            .frame(height: Self.toolbarHeight)
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
    var pins: [DesignPin] = []
    var hotPin: String? = nil
    var onPin: ((String) -> Void)? = nil
    var onPinHover: ((String?) -> Void)? = nil

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
        context.coordinator.onPin = onPin
        context.coordinator.onPinHover = onPinHover
        context.coordinator.setPins(pins, hot: hotPin, in: webView)
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             WKDownloadDelegate {
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
        var onPin: ((String) -> Void)?
        var onPinHover: ((String?) -> Void)?
        // The pins as last sent to the page, so they are sent again only when they change
        // and once more after every load.
        var pinsScript = ""
        var appliedPins = ""

        func setPins(_ pins: [DesignPin], hot: String?, in webView: WKWebView) {
            let list = (try? JSONEncoder().encode(pins)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let hotValue = (try? JSONEncoder().encode(hot)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            pinsScript = "window.__codeStationSetPins?.(\(list), \(hotValue));"
            guard !navigationPending, appliedPins != pinsScript else { return }
            appliedPins = pinsScript
            webView.evaluateJavaScript(pinsScript)
        }

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
            // Pins belong to the review, not the design, so no picture of the design has them.
            webView.evaluateJavaScript("window.__codeStationHidePins?.(true);") { [weak self] _, _ in
                webView.takeSnapshot(with: configuration) { image, _ in
                    webView.evaluateJavaScript("window.__codeStationHidePins?.(false);")
                    self?.onSnapshot?(image, request)
                }
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
            if body["kind"] as? String == "pin" {
                if let id = body["id"] as? String { onPin?(id) }
                return
            }
            if body["kind"] as? String == "pinHover" {
                onPinHover?(body["id"] as? String)
                return
            }

            guard let selection = DesignElementSelection(message: body) else { return }
            onSelection?(selection)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigationPending = false
            appliedPins = pinsScript
            webView.evaluateJavaScript(
                "window.__codeStationSetSelection?.(\(selectionEnabled)); "
                    + "window.__codeStationReportViewport?.(); " + pinsScript)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let allowed = ["file", "about", "data", "blob"].contains(scheme ?? "")
            // A web view drops a link's `download` attribute unless the app takes the
            // file itself, so a design's download button would do nothing.
            if allowed, navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
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

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            guard let destination = FilePicker.saveFile(
                suggestedName: suggestedFilename, prompt: "Save",
                message: "Choose where to save the file from this design.") else {
                completionHandler(nil)
                return
            }
            // The save panel has already asked before replacing a file, and a download
            // fails when its destination exists.
            try? FileManager.default.removeItem(at: destination)
            completionHandler(destination)
        }
    }

    static let pickerHelpers = #"""
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
    """#

    static let pickerEvents = #"""
      document.addEventListener("mouseover", event => {
        if (enabled && !event.target.closest?.("[data-code-station-pins]")) highlight(event.target);
      }, true);

      document.addEventListener("click", event => {
        if (!enabled || event.target.closest?.("[data-code-station-pins]")) return;
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
    """#

    private static let selectionScript = #"""
    (() => {
    \#(Self.pickerHelpers)

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

      window.__codeStationHasScrollContainer = (x, y, deltaX, deltaY) => {
        const phaseOnly = !deltaX && !deltaY;
        let element = document.elementFromPoint(x, y);
        while (element?.shadowRoot?.elementFromPoint) {
          const child = element.shadowRoot.elementFromPoint(x, y);
          if (!child || child === element) break;
          element = child;
        }
        for (; element; element = element.parentElement || element.getRootNode().host) {
          const style = getComputedStyle(element);
          const root = element === document.scrollingElement;
          const scrollable = overflow => /^(auto|scroll|overlay)$/.test(overflow)
            || (root && overflow === "visible");
          // Nested scroll areas keep the gesture at their edges. The page itself
          // must release it so zoom cannot leave part of the artboard out of reach.
          const scrolls = (overflow, delta, offset, range) => {
            if ((!delta && !phaseOnly) || !scrollable(overflow) || range <= 0) return false;
            if (!root || phaseOnly) return true;
            return delta > 0 ? offset > 1 : offset < range - 1;
          };
          const horizontalRange = element.scrollWidth - element.clientWidth;
          const left = element.scrollLeft + (style.direction === "rtl" ? horizontalRange : 0);
          if (scrolls(style.overflowX, deltaX, left, horizontalRange)
              || scrolls(style.overflowY, deltaY, element.scrollTop, element.scrollHeight - element.clientHeight)) return true;
        }
        return false;
      };

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

      // A second opinion's pins, in a layer of their own above the design. Each sits on the
      // element its note names, or on the box the reviewer drew, and follows the page as
      // it lays out again. They are buttons named by their note, so they can be reached
      // and read like any other control.
      var pins = [];
      var hotPin = null;
      var pinsHidden = false;
      var pinLayer = null;
      const pinColours = {must: "#b3412e", should: "#b77a12", look: "#6b6b6b"};
      function post(message) {
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage(message);
      }
      function pinRect(pin) {
        if (pin.selector) {
          try {
            const element = document.querySelector(pin.selector);
            if (element) {
              const rect = element.getBoundingClientRect();
              return {x: rect.left + window.scrollX, y: rect.top + window.scrollY, w: rect.width, h: rect.height};
            }
          } catch (error) {}
        }
        if (pin.box) return {x: pin.box.x, y: pin.box.y, w: pin.box.width, h: pin.box.height};
        return null;
      }
      function drawPins() {
        if (!pinLayer) {
          pinLayer = document.createElement("div");
          pinLayer.setAttribute("data-code-station-pins", "");
          Object.assign(pinLayer.style, {position: "absolute", left: "0", top: "0", width: "0", height: "0",
            zIndex: "2147483647", pointerEvents: "none"});
        }
        if (!pinLayer.isConnected) document.documentElement.appendChild(pinLayer);
        pinLayer.replaceChildren();
        pinLayer.style.display = pinsHidden ? "none" : "";
        for (const pin of pins) {
          const rect = pinRect(pin);
          if (!rect) continue;
          const colour = pinColours[pin.severity] || pinColours.look;
          const hot = pin.id === hotPin;
          const outline = document.createElement("div");
          Object.assign(outline.style, {position: "absolute", left: `${rect.x - 4}px`, top: `${rect.y - 3}px`,
            width: `${rect.w + 8}px`, height: `${rect.h + 6}px`, boxSizing: "border-box", borderRadius: "6px",
            border: `2px ${hot ? "solid" : "dashed"} ${colour}`, background: hot ? `${colour}22` : "transparent",
            opacity: hot ? "1" : "0.7", pointerEvents: "none"});
          const button = document.createElement("button");
          button.type = "button";
          button.textContent = String(pin.number);
          button.title = pin.label;
          button.setAttribute("aria-label", pin.label);
          Object.assign(button.style, {position: "absolute", left: `${rect.x + rect.w - 11}px`, top: `${rect.y - 11}px`,
            width: "22px", height: "22px", borderRadius: "11px", border: "2px solid #fff", background: colour,
            color: "#fff", font: "600 11px -apple-system, system-ui, sans-serif", padding: "0", margin: "0",
            cursor: "pointer", pointerEvents: "auto", boxShadow: hot ? `0 0 0 3px ${colour}55` : "0 1px 3px rgba(0,0,0,.3)"});
          button.addEventListener("click", event => {
            event.preventDefault();
            event.stopImmediatePropagation();
            post({kind: "pin", id: pin.id});
          }, true);
          button.addEventListener("mouseenter", () => post({kind: "pinHover", id: pin.id}));
          button.addEventListener("mouseleave", () => post({kind: "pinHover", id: null}));
          pinLayer.append(outline, button);
        }
      }
      window.__codeStationSetPins = (list, hot) => {
        pins = Array.isArray(list) ? list : [];
        hotPin = hot || null;
        drawPins();
      };
      window.__codeStationHidePins = hidden => {
        pinsHidden = Boolean(hidden);
        if (pinLayer) pinLayer.style.display = pinsHidden ? "none" : "";
      };
      new ResizeObserver(() => { if (pins.length) drawPins(); }).observe(document.documentElement);

      window.__codeStationSetSelection = value => {
        stopDrag();
        enabled = Boolean(value);
        document.documentElement.style.cursor = enabled ? "crosshair" : "";
        if (!enabled) clearHighlight();
      };

    \#(Self.pickerEvents)
    })();
    """#
}

// One note's pin on the canvas: where it goes and how it reads.
struct DesignPin: Encodable, Equatable {
    let id: String
    var selector: String?
    var box: DesignSecondOpinion.Box?
    let severity: String
    let number: Int
    let label: String
}

extension DesignElementSelection {
    init?(message body: [String: Any]) {
        guard let selector = body["selector"] as? String,
              let tag = body["tag"] as? String,
              let rect = body["rect"] as? [String: Any],
              let x = rect["x"] as? Double,
              let y = rect["y"] as? Double,
              let width = rect["width"] as? Double,
              let height = rect["height"] as? Double else { return nil }
        self.init(
            selector: selector,
            tag: tag,
            text: (body["text"] as? String ?? "").trimmed,
            rect: CGRect(x: x, y: y, width: width, height: height))
    }

    func reference(at place: String) -> String {
        let label = text.isEmpty ? tag.uppercased() : "\"\(text)\""
        return "Refine \(label) at \(place). "
    }
}
