import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MenuBarApp

struct HTMLPreviewTests {
    private let marker = "\u{E200}visualize\u{E202}{\"path\":\"output/preview.html\",\"title\":\"Agent preview\",\"mode\":\"wide\"}\u{E201}"

    @Test func recognizesPreviewBetweenProseAndKeepsMetadata() throws {
        let reference = try #require(HTMLPreviewReference.parse(marker))
        #expect(reference.path == "output/preview.html")
        #expect(reference.title == "Agent preview")
        #expect(reference.mode == "wide")
        #expect(MarkdownBlock.parse("Before\n\(marker)\nAfter").map(\.kind) == [
            .paragraph("Before"), .htmlPreview(reference), .paragraph("After"),
        ])
        #expect(MarkdownBlock.parse("\(marker)\n\(marker)").map(\.id) == [0, 1])
    }

    @Test func keepsCodeAndMalformedMarkersAsText() {
        let samples = ["`\(marker)`", String(marker.dropLast()),
                       "\u{E200}visualize\u{E202}{\"path\":42}\u{E201}",
                       "\u{E200}visualize\u{E202}{\"path\":\" \"}\u{E201}",
                       "\u{E200}visualize\u{E202}{broken}\u{E201}"]
        for text in samples {
            #expect(MarkdownBlock.parse(text).map(\.kind) == [.paragraph(text)])
        }
        #expect(MessageSegment.split("```text\n\(marker)\n```") == [
            MessageSegment(id: 1, text: marker, isCode: true, language: "text"),
        ])
    }

    @Test func readsLocalFilesIncludingPathsWithSpecialCharacters() throws {
        let scratch = ScratchDirectory()
        let file = scratch.path("preview #1%20?.html")
        try "<div>Hello</div>".write(to: file, atomically: true, encoding: .utf8)
        for path in [file.path, file.absoluteString, file.lastPathComponent] {
            let reference = HTMLPreviewReference(path: path)
            #expect(try reference.fileURL(projectPath: scratch.url.path) == file)
            let document = try HTMLPreviewDocument.read(reference, projectPath: scratch.url.path)
            #expect(document.html.contains("<div>Hello</div>"))
        }
    }

    @Test func rejectsRemotePathsAndNonHTMLFiles() {
        for path in ["https://example.com/index.html", "file://example.com/index.html",
                     "//example.com/index.html", "javascript:alert(1)", "notes.txt"] {
            #expect(throws: HTMLPreviewDocument.Failure.self) {
                try HTMLPreviewReference(path: path).fileURL(projectPath: "/tmp")
            }
        }
    }

    @Test func reportsMissingOversizedAndInvalidFiles() throws {
        let scratch = ScratchDirectory()
        let file = scratch.path("preview.html")
        let reference = HTMLPreviewReference(path: file.path)
        #expect(throws: HTMLPreviewDocument.Failure.self) {
            try HTMLPreviewDocument.read(reference, projectPath: scratch.url.path)
        }
        try Data(repeating: 65, count: 1_000_001).write(to: file)
        #expect(throws: HTMLPreviewDocument.Failure.self) {
            try HTMLPreviewDocument.read(reference, projectPath: scratch.url.path)
        }
        try Data([0xff, 0xfe]).write(to: file)
        #expect(throws: HTMLPreviewDocument.Failure.self) {
            try HTMLPreviewDocument.read(reference, projectPath: scratch.url.path)
        }
        let directory = scratch.path("folder.html")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: HTMLPreviewDocument.Failure.self) {
            try HTMLPreviewDocument.read(HTMLPreviewReference(path: directory.path),
                                         projectPath: scratch.url.path)
        }
    }
}

@MainActor
@Suite(.serialized)
struct HTMLPreviewWebTests {
    @Test func rendersInteractiveHTMLReportsHeightAndBlocksFileAccess() async throws {
        let coordinator = HTMLPreviewWebContent.Coordinator()
        let webView = HTMLPreviewWebContent.makeWebView(coordinator: coordinator)
        webView.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            HTMLPreviewWebContent.dismantleNSView(webView, coordinator: coordinator)
            window.contentView = nil
        }
        var reportedHeight: CGFloat = 0
        coordinator.onHeight = { reportedHeight = $0 }
        let scratch = ScratchDirectory()
        let secret = scratch.path("private.txt")
        try "private content".write(to: secret, atomically: true, encoding: .utf8)
        let document = HTMLPreviewDocument(content: """
            <button id="toggle" onclick="document.getElementById('details').hidden = false">Show</button>
            <div id="details" hidden style="height:600px">Agent details</div>
            <script>
            window.fileRead = 'pending';
            fetch('\(secret.absoluteString)').then(r => r.text()).then(() => window.fileRead = 'allowed')
              .catch(() => window.fileRead = 'blocked');
            window.ready = true;
            </script>
            """, stylesheet: "body { margin: 0; display: flow-root; }")
        webView.loadHTMLString(document.html, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript("window.ready")) as? Bool == true,
               reportedHeight > 0 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await webView.evaluateJavaScript("window.ready") as? Bool == true)
        #expect(try await webView.evaluateJavaScript("window.fileRead") as? String == "blocked")
        #expect(try await webView.evaluateJavaScript(
            "typeof window.webkit?.messageHandlers?.codeStationPreviewHeight") as? String == "undefined")
        let initialHeight = reportedHeight
        _ = try await webView.evaluateJavaScript("document.getElementById('toggle').click()")
        #expect(await waitUntil(timeout: .seconds(5)) { reportedHeight > initialHeight + 500 })
        #expect(try await webView.evaluateJavaScript("document.getElementById('details').hidden") as? Bool == false)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
    }
}

@MainActor
@Suite(.serialized)
struct HTMLPreviewTranscriptTests {
    @Test func preservesInteractiveStateAsTheReplyStreamsAndResizes() async throws {
        let scratch = ScratchDirectory()
        try """
            <button id="counter" onclick="this.textContent = Number(this.textContent) + 1">0</button>
            <script>window.ready = true;</script>
            """.write(to: scratch.path("preview.html"), atomically: true, encoding: .utf8)
        let marker = "\u{E200}visualize\u{E202}{\"path\":\"preview.html\"}\u{E201}"
        let dialogs = DialogPresenter()
        let tooltips = TooltipPresenter()
        func content(_ text: String) -> some View {
            MarkdownProse(text: text, projectPath: scratch.url.path, textScale: 1) {
                MarkdownCodeBlock(segment: $0)
            }
            .environment(dialogs)
            .environment(tooltips)
        }
        let host = NSHostingView(rootView: content(marker))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        func webView(in view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        #expect(await waitUntil(timeout: .seconds(10)) {
            host.layoutSubtreeIfNeeded()
            return webView(in: host) != nil
        })
        let preview = try #require(webView(in: host))
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if (try? await preview.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        _ = try await preview.evaluateJavaScript("document.getElementById('counter').click()")
        host.rootView = content(marker + "\nMore explanation arriving after the preview.")
        window.setContentSize(CGSize(width: 360, height: 700))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(webView(in: host) === preview)
        #expect(preview.frame.width <= 360)
        #expect(try await preview.evaluateJavaScript("document.getElementById('counter').textContent") as? String == "1")
    }
}
