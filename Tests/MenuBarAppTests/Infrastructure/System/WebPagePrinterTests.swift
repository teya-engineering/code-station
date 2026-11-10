import AppKit
import Testing
import WebKit
@testable import MenuBarApp

// These never start a real print job: a test host has no running app to show the print
// panel, so the job would go straight to the printer.
@MainActor
@Suite(.serialized)
struct WebPagePrinterTests {
    @Test func everyPreviewTakesOverThePagePrintFunction() async throws {
        let design = DesignWebContent.Coordinator()
        let explorer = HTMLPreviewWebContent.Coordinator()
        let server = LocalServerPreviewWebContent.Coordinator()
        let webViews = [
            DesignWebContent.makeViewport(coordinator: design).webView,
            HTMLPreviewWebContent.makeWebView(coordinator: explorer),
            LocalServerPreviewWebContent.makeWebView(coordinator: server),
        ]
        for webView in webViews {
            try await load(in: webView) {
                let source = try await webView.evaluateJavaScript("String(window.print)") as? String
                #expect(source?.contains("[native code]") == false)
            }
        }
    }

    @Test func aPagePrintButtonAsksTheAppToPrintThatPage() async throws {
        var printed: [WKWebView] = []
        let configuration = WKWebViewConfiguration()
        WebPagePrinter.install(in: configuration.userContentController,
                               printer: WebPagePrinter { printed.append($0) })
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try await load(in: webView) {
            _ = try await webView.evaluateJavaScript("document.getElementById('print').click()")
            #expect(await waitUntil(timeout: .seconds(10)) { printed.count == 1 })
            #expect(printed.first === webView)
        }
    }

    @Test func readsThePrintPageRuleAndSkipsScreenOnlyRules() async throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        try await load(in: webView, style: """
            @page { margin: 0.5in }
            @media screen { @page { size: A3 } }
            @media print { @page { size: 14in 11.25in; margin: 0 } }
            """) {
            let value = try await webView.evaluateJavaScript(
                PrintPageStyle.readScript, in: nil, contentWorld: .defaultClient)
            let rule = try #require(value as? [String: String])
            #expect(PrintPageStyle(rule: rule) == PrintPageStyle(
                paperSize: CGSize(width: 1008, height: 810), orientation: .landscape,
                margins: [.top: 0, .right: 0, .bottom: 0, .left: 0]))
        }
    }

    private func load(in webView: WKWebView, style: String = "",
                      _ check: () async throws -> Void) async throws {
        webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        webView.loadHTMLString("""
            <style>\(style)</style>
            <button id="print" onclick="window.print()">Print poster</button>
            <script>window.ready = true;</script>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline,
              (try? await webView.evaluateJavaScript("window.ready")) as? Bool != true {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await webView.evaluateJavaScript("window.ready") as? Bool == true)
        try await check()
    }
}

struct PrintPageStyleTests {
    @Test func readsNamedSizesLengthsAndOrientation() {
        #expect(PrintPageStyle(rule: ["size": "A4"])
            == PrintPageStyle(paperSize: CGSize(width: 595.28, height: 841.89), orientation: .portrait))
        #expect(PrintPageStyle(rule: ["size": "letter landscape"])
            == PrintPageStyle(paperSize: CGSize(width: 792, height: 612), orientation: .landscape))
        #expect(PrintPageStyle(rule: ["size": "210mm 297mm"]).paperSize?.width.rounded() == 595)
        #expect(PrintPageStyle(rule: ["size": "6in"])
            == PrintPageStyle(paperSize: CGSize(width: 432, height: 432), orientation: .portrait))
        #expect(PrintPageStyle(rule: ["size": "1344px 1080px"])
            == PrintPageStyle(paperSize: CGSize(width: 1008, height: 810), orientation: .landscape))
        #expect(PrintPageStyle(rule: ["size": "landscape"]) == PrintPageStyle(orientation: .landscape))
    }

    @Test func ignoresSizesItCannotRead() {
        for size in ["auto", "", "10% 20%", "0in 5in", "A4 nonsense", "-3in"] {
            #expect(PrintPageStyle(rule: ["size": size]).paperSize == nil, "\(size)")
        }
        #expect(PrintPageStyle(rule: ["margin-top": "5%", "margin-left": "1cm"]).margins
            == [.left: 72 / 2.54])
    }

    @Test func appliesThePaperOverTheAppPaper() throws {
        let info = try #require(NSPrintInfo.shared.copy() as? NSPrintInfo)
        info.orientation = .portrait
        PrintPageStyle(rule: ["size": "14in 11.25in", "margin-top": "0", "margin-left": "0.25in"])
            .apply(to: info)
        #expect(info.paperSize == CGSize(width: 1008, height: 810))
        #expect(info.orientation == .landscape)
        #expect(info.topMargin == 0)
        #expect(info.leftMargin == 18)

        let turned = try #require(NSPrintInfo.shared.copy() as? NSPrintInfo)
        turned.orientation = .portrait
        let portrait = turned.paperSize
        PrintPageStyle(rule: ["size": "landscape"]).apply(to: turned)
        #expect(turned.orientation == .landscape)
        #expect(turned.paperSize == CGSize(width: portrait.height, height: portrait.width))
    }
}
