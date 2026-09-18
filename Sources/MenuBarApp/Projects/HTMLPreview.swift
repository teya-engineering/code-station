import AppKit
import SwiftUI
import WebKit

struct HTMLPreviewReference: Decodable, Equatable, Sendable {
    let path: String
    var title: String?
    var mode: String?

    static func parse(_ text: String) -> HTMLPreviewReference? {
        guard let payload = TranscriptMarker.payload(of: text, named: "visualize"),
              let reference = try? JSONDecoder().decode(Self.self, from: Data(payload.utf8)),
              !reference.path.trimmed.isEmpty else { return nil }
        return reference
    }

    var label: String {
        if let title, !title.trimmed.isEmpty { return title }
        return (path as NSString).lastPathComponent.removingPercentEncoding ?? "HTML preview"
    }

    func fileURL(projectPath: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/"), !path.hasPrefix("//") {
            url = URL(fileURLWithPath: path)
        } else if let parsed = URL(string: path), parsed.isFileURL,
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost" {
            url = parsed
        } else {
            guard !path.hasPrefix("//"), let parsed = URL(string: path),
                  parsed.scheme == nil, parsed.host == nil else {
                throw HTMLPreviewDocument.Failure.localHTMLRequired
            }
            let expanded = (path as NSString).expandingTildeInPath
            url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: projectPath).appendingPathComponent(expanded)
        }
        guard ["html", "htm"].contains(url.pathExtension.lowercased()) else {
            throw HTMLPreviewDocument.Failure.localHTMLRequired
        }
        return url.standardizedFileURL
    }
}

struct HTMLPreviewDocument: Sendable {
    let html: String

    enum Failure: LocalizedError {
        case localHTMLRequired, unavailable, tooLarge, invalidText, missingResources

        var errorDescription: String? {
            switch self {
            case .localHTMLRequired: "Previews need a local HTML file."
            case .unavailable: "The HTML file is missing or cannot be read."
            case .tooLarge: "The HTML file is larger than 1 MB."
            case .invalidText: "The HTML file is not UTF-8 text."
            case .missingResources: "Preview resources are missing. Rebuild or reinstall the app."
            }
        }
    }

    static func read(_ reference: HTMLPreviewReference, projectPath: String) throws -> Self {
        let url = try reference.fileURL(projectPath: projectPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw Failure.unavailable }
        guard (values.fileSize ?? 0) <= 1_000_000 else { throw Failure.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unavailable }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 1_000_001) else { throw Failure.unavailable }
        guard data.count <= 1_000_000 else { throw Failure.tooLarge }
        guard let content = String(data: data, encoding: .utf8) else { throw Failure.invalidText }
        guard let stylesheetURL = AppResources.bundle.url(
            forResource: "html-preview", withExtension: "css") else { throw Failure.missingResources }
        let stylesheet = try String(contentsOf: stylesheetURL, encoding: .utf8)
        return Self(content: content, stylesheet: stylesheet)
    }

    init(content: String, stylesheet: String) {
        // Loading text with no file base URL keeps the preview from reading nearby files.
        // The policy comes before the fragment so its own markup cannot relax it.
        let sources = "https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://esm.sh "
            + "https://unpkg.com https://fonts.googleapis.com https://fonts.gstatic.com "
            + "https://fonts.bunny.net"
        html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';
          script-src 'unsafe-inline' \(sources); style-src 'unsafe-inline' \(sources);
          img-src data: blob: \(sources); font-src data: \(sources); media-src data: blob: \(sources);
          connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(stylesheet)</style></head><body>
        \(content)
        <script async src="https://unpkg.com/lucide@1.17.0/dist/umd/lucide.js"
          onload="lucide.createIcons({attrs:{width:16,height:16}})"></script>
        <script>
        document.addEventListener('click', event => {
          const tab = event.target.closest('[role="tab"][aria-controls]');
          if (!tab || tab.disabled || tab.getAttribute('aria-disabled') === 'true') return;
          const list = tab.closest('[role="tablist"]');
          if (!list) return;
          for (const item of list.querySelectorAll('[role="tab"]')) {
            const active = item === tab;
            item.setAttribute('aria-selected', String(active));
            item.classList.toggle('active', active);
            const panel = document.getElementById(item.getAttribute('aria-controls'));
            if (panel) panel.hidden = !active;
          }
        });
        </script></body></html>
        """
    }
}

struct HTMLPreview: View {
    let reference: HTMLPreviewReference
    let projectPath: String
    @Environment(DialogPresenter.self) private var dialogs
    @State private var document: HTMLPreviewDocument?
    @State private var failure: String?
    @State private var height: CGFloat = 320
    @State private var reloadGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label(reference.label, systemImage: "globe")
                    .scaledText(11, .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { reloadGeneration += 1 } label: {
                    Text("Reload").contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let document {
                    Button { expand(document) } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scaledText(11, .medium)
            .foregroundStyle(Theme.accent)
            .padding(12)
            .background(Theme.card)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let failure {
                Text(failure)
                    .scaledText(12)
                    .foregroundStyle(Theme.warningText)
                    .textSelection(.enabled)
                    .padding(16)
            } else if let document {
                HTMLPreviewWebContent(html: document.html, onHeight: { height = $0 },
                                      onFailure: { failure = $0 })
                    .frame(height: min(max(height, 96), reference.mode == "wide" ? 720 : 560))
            } else {
                Text("Loading preview…")
                    .scaledText(12)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .task(id: "\(projectPath):\(reference.path):\(reloadGeneration)") {
            document = nil
            failure = nil
            let result = await Task.detached {
                Result { try HTMLPreviewDocument.read(reference, projectPath: projectPath) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded): document = loaded
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func expand(_ document: HTMLPreviewDocument) {
        let size = NSApp.keyWindow?.contentView?.bounds.size ?? CGSize(width: 1100, height: 800)
        dialogs.show(Dialog(
            title: reference.label,
            content: AnyView(HTMLPreviewWebContent(html: document.html)
                .frame(height: max(240, min(800, size.height - 200)))),
            actions: [.init(label: "Close", kind: .cancel)],
            width: max(320, min(1100, size.width - 80))))
    }
}

struct HTMLPreviewWebContent: NSViewRepresentable {
    let html: String
    var onHeight: (CGFloat) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient,
                                                 name: Coordinator.messageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            (() => {
              const report = () => {
                window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(
                  Math.max(document.body.offsetHeight, document.body.scrollHeight));
              };
              new ResizeObserver(report).observe(document.body);
              window.addEventListener('load', report);
              report();
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.underPageBackgroundColor = Theme.backgroundNSColor
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailure = onFailure
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageName, contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "codeStationPreviewHeight"
        var loadedHTML: String?
        var onHeight: (CGFloat) -> Void = { _ in }
        var onFailure: (String) -> Void = { _ in }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let height = message.body as? Double,
                  height.isFinite, height > 0 else { return }
            onHeight(CGFloat(height))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.targetFrame?.isMainFrame == true,
               let url, url.absoluteString == "about:blank"
                || url.absoluteString.hasPrefix("about:blank#") {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure("The HTML preview could not load. \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                onFailure("The HTML preview could not load. \(error.localizedDescription)")
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure("The HTML preview stopped. Reload to try again.")
        }
    }
}
