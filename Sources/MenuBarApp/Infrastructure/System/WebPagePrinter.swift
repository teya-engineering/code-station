import AppKit
import WebKit

// A web view inside an app drops `window.print()`: WebKit prints only when the app takes
// the request, and macOS has no public delegate call for it. So the page's print function
// is swapped for a message, and the app answers it with the system print panel.
@MainActor
final class WebPagePrinter: NSObject, WKScriptMessageHandler {
    static let messageName = "codeStationPrint"

    private let onPrint: @MainActor (WKWebView) -> Void

    init(onPrint: @escaping @MainActor (WKWebView) -> Void = WebPagePrinter.print) {
        self.onPrint = onPrint
    }

    // The script and its handler live in the page's own world, since that is where the
    // page calls `print`. Added at document start, so the page never holds the old one.
    static func install(in controller: WKUserContentController,
                        printer: WebPagePrinter = WebPagePrinter()) {
        controller.add(printer, name: messageName)
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
              const handler = window.webkit?.messageHandlers?.\(messageName);
              if (!handler) return;
              window.print = () => handler.postMessage('print');
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        onPrint(webView)
    }

    static func print(_ webView: WKWebView) {
        guard let window = webView.window, window.attachedSheet == nil else { return }
        webView.evaluateJavaScript(PrintPageStyle.readScript, in: nil, in: .defaultClient) { result in
            guard webView.window === window, window.attachedSheet == nil else { return }
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
            if case .success(let value) = result, let rule = value as? [String: String] {
                PrintPageStyle(rule: rule).apply(to: info)
            }
            let operation = webView.printOperation(with: info)
            operation.jobTitle = webView.title.flatMap { $0.isEmpty ? nil : $0 }
            // Without a frame the web view's print view lays out at zero size and prints
            // blank pages.
            operation.view?.frame = webView.bounds
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

// The paper a page asks for with a CSS `@page` rule. The web view's print path ignores
// that rule and uses the app's paper instead, so a page laid out for its own paper, such
// as a poster, would be cut off at the edge.
struct PrintPageStyle: Equatable {
    var paperSize: CGSize?
    var orientation: NSPrintInfo.PaperOrientation?
    var margins: [Edge: CGFloat] = [:]

    enum Edge: String, CaseIterable { case top, right, bottom, left }

    // Reads the `size` and `margin` of the page's `@page` rules that apply to print. Rules
    // in sheets from another origin cannot be read and are skipped.
    static let readScript = """
        (() => {
          const found = {};
          const forPrint = (media) => {
            const text = media.mediaText.toLowerCase();
            return text === '' || text.includes('print') || text.includes('all');
          };
          const walk = (rules) => {
            for (const rule of rules) {
              if (rule instanceof CSSPageRule && !rule.selectorText) {
                for (const name of ['size', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left']) {
                  const value = rule.style.getPropertyValue(name);
                  if (value) found[name] = value;
                }
              } else if (rule instanceof CSSMediaRule && forPrint(rule.media)) {
                walk(rule.cssRules);
              }
            }
          };
          for (const sheet of document.styleSheets) {
            if (sheet.media && !forPrint(sheet.media)) continue;
            try { walk(sheet.cssRules); } catch {}
          }
          return found;
        })();
        """

    // Named sizes are portrait, in points.
    private static let namedSizes: [String: CGSize] = [
        "a5": CGSize(width: 419.53, height: 595.28),
        "a4": CGSize(width: 595.28, height: 841.89),
        "a3": CGSize(width: 841.89, height: 1190.55),
        "b5": CGSize(width: 498.9, height: 708.66),
        "b4": CGSize(width: 708.66, height: 1000.63),
        "jis-b5": CGSize(width: 515.91, height: 728.5),
        "jis-b4": CGSize(width: 728.5, height: 1031.81),
        "letter": CGSize(width: 612, height: 792),
        "legal": CGSize(width: 612, height: 1008),
        "ledger": CGSize(width: 792, height: 1224),
    ]

    private static let pointsPerUnit: [String: CGFloat] = [
        "in": 72, "cm": 72 / 2.54, "mm": 72 / 25.4, "q": 72 / 101.6,
        "pt": 1, "pc": 12, "px": 0.75,
    ]

    init(paperSize: CGSize? = nil, orientation: NSPrintInfo.PaperOrientation? = nil,
         margins: [Edge: CGFloat] = [:]) {
        self.paperSize = paperSize
        self.orientation = orientation
        self.margins = margins
    }

    init(rule: [String: String]) {
        for edge in Edge.allCases {
            if let value = rule["margin-\(edge.rawValue)"], let points = Self.points(value) {
                margins[edge] = points
            }
        }
        let words = (rule["size"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var lengths: [CGFloat] = []
        var named: CGSize?
        for word in words {
            if word == "landscape" {
                orientation = .landscape
            } else if word == "portrait" {
                orientation = .portrait
            } else if let size = Self.namedSizes[word] {
                named = size
            } else if let points = Self.points(word) {
                lengths.append(points)
            } else {
                return
            }
        }
        if lengths.count == 1 {
            paperSize = CGSize(width: lengths[0], height: lengths[0])
        } else if lengths.count == 2 {
            paperSize = CGSize(width: lengths[0], height: lengths[1])
        } else if var named {
            if orientation == .landscape { named = CGSize(width: named.height, height: named.width) }
            paperSize = named
        }
        if let paperSize, paperSize.width <= 0 || paperSize.height <= 0 { self.paperSize = nil }
        if let paperSize { orientation = paperSize.width > paperSize.height ? .landscape : .portrait }
    }

    private static func points(_ text: String) -> CGFloat? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "0" { return 0 }
        guard let unit = pointsPerUnit.keys.first(where: { text.hasSuffix($0) }),
              let number = Double(text.dropLast(unit.count)), number >= 0, number.isFinite
        else { return nil }
        return CGFloat(number) * pointsPerUnit[unit]!
    }

    func apply(to info: NSPrintInfo) {
        // Setting the orientation turns the current paper, so the size is set after it.
        if let orientation { info.orientation = orientation }
        if let paperSize { info.paperSize = paperSize }
        if let top = margins[.top] { info.topMargin = top }
        if let right = margins[.right] { info.rightMargin = right }
        if let bottom = margins[.bottom] { info.bottomMargin = bottom }
        if let left = margins[.left] { info.leftMargin = left }
    }
}
