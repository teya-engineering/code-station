import AppKit
import Network
import SwiftUI
import Testing
import WebKit
@testable import MenuBarApp
@testable import CodeStationCore

private func url(_ text: String) -> URL { URL(string: text)! }

// Where a test clicks on a page: a box with its top left corner at x and y.
private func box(_ x: Int, _ y: Int) -> String {
    "style=\"position:absolute; left:\(x)px; top:\(y)px; width:200px; height:80px\""
}

// The bar, the message and Reload all go by what the preview holds, so after each load it
// has to hold the page a person expects: the one still on screen, or the one that did not
// load.
@MainActor
struct LocalServerPreviewTests {
    @Test func holdsThePageAPersonExpectsAfterEachLoad() {
        let preview = LocalServerPreview(opening: url("http://localhost:3000/#/billing"))
        #expect(preview.phase == .opening)
        preview.finishLoading(hasPage: true)
        #expect(preview.phase == .showing)
        preview.follow(url("http://localhost:3000/settings"))
        #expect(preview.address == url("http://localhost:3000/settings"))
        preview.reload()
        #expect(preview.phase == .showing)

        preview.open(url("http://localhost:5173/"))
        preview.phase = .unreachable
        preview.finishLoading(hasPage: true)
        preview.follow(url("http://localhost:3000/settings"))
        #expect(preview.phase == .unreachable)
        #expect(preview.address == url("http://localhost:5173/"))
        preview.reload()
        #expect(preview.phase == .opening)
        #expect(preview.reloadGeneration == 4)
        preview.finishLoading(hasPage: false)
        #expect(preview.phase == .noPage)
    }

    @Test func namesOnlyTheServerAndItsPage() {
        let addresses = ["http://localhost:3000/", "http://[::1]:5173/settings?token=abc",
                         "http://localhost:3000/#/billing?token=abc", "http://localhost:3000/docs#intro",
                         "http://ada:secret@localhost:8000/settings"]

        #expect(addresses.map { LocalServerPreview.label(for: url($0)) } == [
            "localhost:3000", "[::1]:5173/settings", "localhost:3000/#/billing", "localhost:3000/docs",
            "localhost:8000/settings",
        ])
    }

    // A port keeps the name its sign-in is kept under, and the page's own server keeps its https.
    @Test func readsATypedAddressAsAPageOnThisMachine() {
        let typed: [(text: String, on: String?, address: String)] = [
            ("localhost:3000/settings", nil, "http://localhost:3000/settings"),
            (" 127.0.0.1:8080 ", nil, "http://127.0.0.1:8080"), ("[::1]:5173/", nil, "http://[::1]:5173/"),
            ("https://localhost:5173/a?tab=2", nil, "https://localhost:5173/a?tab=2"),
            ("HTTP://LocalHost:3000/Settings", nil, "http://localhost:3000/Settings"),
            ("localhost:3000/login?next=http://localhost:3000/", nil,
             "http://localhost:3000/login?next=http://localhost:3000/"),
            ("/settings", "http://localhost:5173/app?tab=2", "http://localhost:5173/settings"),
            ("#/billing", "http://localhost:5173/app?tab=2", "http://localhost:5173/app?tab=2#/billing"),
            ("3000", nil, "http://localhost:3000"), (":8080", nil, "http://localhost:8080"),
            (":3000/settings", nil, "http://localhost:3000/settings"),
            (":8000/admin/users", "http://127.0.0.1:8000/admin/", "http://127.0.0.1:8000/admin/users"),
            ("3000", "http://[::1]:5173/", "http://[::1]:3000"),
            ("localhost:5173/settings", "https://localhost:5173/", "https://localhost:5173/settings"),
            (":5173", "https://localhost:5173/", "https://localhost:5173"),
            ("8443", "https://127.0.0.1:8443/", "https://127.0.0.1:8443"),
            ("localhost:3000", "https://localhost:5173/", "http://localhost:3000"),
        ]

        for (text, page, address) in typed {
            #expect(LocalServerPreview.address(text, on: page.map(url))?.absoluteString == address)
        }
    }

    @Test func readsTextThatIsNoAddressAsNothing() {
        let typed = ["", "   ", "file://localhost/etc/passwd", "ftp://localhost/", "http://:3000", "/settings"]

        #expect(typed.allSatisfy { LocalServerPreview.address($0, on: nil) == nil })
    }

    @Test func holdsAnAddressElsewhereBackOverThePage() {
        let preview = LocalServerPreview(opening: url("http://localhost:3000/settings"))
        preview.phase = .showing

        #expect(preview.open(typed: "example.com"))
        #expect(preview.open(typed: "example.org/docs"))
        #expect(!preview.open(typed: "file://localhost/etc/passwd"))
        #expect(preview.phase == .elsewhere(url("http://example.org/docs"), over: .showing))
        #expect(preview.address == url("http://localhost:3000/settings"))
        #expect(preview.reloadGeneration == 1)
        preview.stay()
        #expect(preview.phase == .showing)
        #expect(preview.open(typed: "example.com"))
        preview.reload()
        #expect(preview.phase == .showing)
        #expect(preview.reloadGeneration == 2)

        preview.phase = .opening
        #expect(preview.open(typed: "example.com"))
        preview.finishLoading(hasPage: false)
        preview.follow(url("http://localhost:3000/next"))
        #expect(preview.phase == .elsewhere(url("http://example.com"), over: .noPage))
        #expect(preview.address == url("http://localhost:3000/settings"))
        preview.stay()
        #expect(preview.phase == .noPage)
    }

    // Back leads out from under a message only to a page that was shown, whatever the history.
    @Test func backAndForwardFollowThePagesHistory() {
        let preview = LocalServerPreview(opening: url("http://localhost:3000/"))
        _ = preview.webView
        preview.coordinator.onHistory(true, true)
        preview.phase = .showing
        #expect(preview.canGoBack && preview.canGoForward)
        preview.phase = .unreachable
        #expect(!preview.canGoBack && !preview.canGoForward)

        preview.coordinator.onHistory(false, false)
        preview.phase = .showing
        #expect(preview.open(typed: "example.com"))
        #expect(preview.canGoBack && !preview.canGoForward)
        preview.goBack()
        #expect(preview.phase == .showing)
    }
}

// A link has to land on the page a person expects, and closing a page has to leave the right
// one showing.
@MainActor
struct LocalServerPreviewTabsTests {
    @Test func aLinkLandsOnThePageAPersonExpects() throws {
        let previews = LocalServerPreviewTabs()
        previews.open(url("http://localhost:3000/"))
        let home = try #require(previews.selected)
        previews.open(url("http://localhost:3000/billing"))
        #expect(previews.pages.count == 1)
        #expect(previews.selected === home)
        #expect(home.address.path == "/billing")
        previews.open(url("http://localhost:3000/billing?tab=2"), inNewPage: true)
        let billing = try #require(previews.selected)
        #expect(billing !== home)
        #expect(home.address.absoluteString == "http://localhost:3000/billing")
        previews.open(url("http://localhost:3000/billing"))
        #expect(previews.selected === billing)

        previews.select(home)
        previews.open(url("http://localhost:3000/settings"))
        previews.open(url("http://localhost:3000/billing?tab=3"))
        #expect(previews.pages.count == 2)
        #expect(previews.selected === billing)
        #expect(billing.address.absoluteString == "http://localhost:3000/billing?tab=3")
        #expect(home.address.path == "/settings")
    }

    @Test func closingAPageShowsTheOneBesideIt() {
        let previews = LocalServerPreviewTabs()
        for path in ["/", "/settings", "/billing", "/team"] {
            previews.open(url("http://localhost:3000" + path), inNewPage: true)
        }
        let pages = previews.pages
        previews.select(pages[1])

        previews.close(pages[3])
        #expect(previews.pages.count == 3)
        #expect(previews.selected === pages[1])
        previews.close(pages[1])
        #expect(previews.selected === pages[2])
        previews.close(pages[2])
        #expect(previews.selected === pages[0])
        #expect(previews.isOpen)
        previews.close(pages[0])
        #expect(previews.pages.isEmpty)
        #expect(previews.selected == nil)
        #expect(!previews.isOpen)
    }

    @Test func hidingThePreviewKeepsItsPagesWhichShareOneSignIn() {
        let previews = LocalServerPreviewTabs(), elsewhere = LocalServerPreviewTabs()
        previews.open(url("http://localhost:3000/"))
        previews.open(url("http://localhost:3000/settings"), inNewPage: true)
        elsewhere.open(url("http://localhost:3000/"))

        previews.hide()
        #expect(!previews.isOpen)
        #expect(previews.pages.count == 2)
        previews.show()
        #expect(previews.isOpen)
        #expect(previews.selected === previews.pages[1])
        let stores = (previews.pages + elsewhere.pages).map { $0.webView.configuration.websiteDataStore }
        #expect(stores[0] === stores[1])
        #expect(stores[0] !== stores[2])
    }
}

// An agent reads a pick, so it names the element and its page once, as a pick on Design does.
@MainActor
struct LocalServerPreviewDraftTests {
    @Test func writesAPickAsAReferenceToItsPageOncePerPage() {
        let save = DesignElementSelection(selector: "#save", tag: "button", text: "Save", rect: .zero)
        let image = DesignElementSelection(selector: "main > img", tag: "img", text: "", rect: .zero)
        let settings = url("http://localhost:5173/settings?token=abc#top")
        let first = LocalServerPreview.draft("Make these match.", adding: save, on: settings)

        #expect(LocalServerPreview.draft("", adding: save, on: settings)
                == "Refine \"Save\" at `#save` on `/settings`. ")
        #expect(LocalServerPreview.draft("", adding: image, on: url("http://localhost:5173"))
                == "Refine IMG at `main > img` on `/`. ")
        #expect(first == "Make these match.\n\nRefine \"Save\" at `#save` on `/settings`. ")
        #expect(LocalServerPreview.draft(first, adding: save, on: settings) == first)
        #expect(LocalServerPreview.draft(first, adding: save, on: url("http://localhost:5173/#/billing"))
                == first + "\n\nRefine \"Save\" at `#save` on `/#/billing`. ")
    }
}

// A running app is someone's real work, so the picker stays out of its way: the page cannot
// see or drive it, its crosshair lasts through the app's own documents and sheets without
// touching the page's styles, and with it off every gesture is the app's own.
@MainActor
@Suite(.serialized)
struct LocalServerPreviewWebTests {
    private let app = """
        <button id="save" \(box(100, 100))>Save</button>
        <button id="cancel" \(box(400, 100))>Cancel</button>
        <input id="agree" type="checkbox">
        <script>
        var presses = 0, clicks = 0, save = document.getElementById("save");
        var types = ["pointerdown", "mousedown", "pointerup", "mouseup", "dblclick", "contextmenu", "auxclick"];
        for (const type of types) save.addEventListener(type, () => presses++);
        document.addEventListener("click", () => clicks++, true);
        // Every press the picker stops, then a click, all made by the page's own script.
        var gestures = () => {
          for (const type of types) {
            const Event = type.startsWith("pointer") ? PointerEvent : MouseEvent;
            save.dispatchEvent(new Event(type, {bubbles: true, cancelable: true}));
          }
          save.click();
        };
        window.ready = true;
        </script>
        """

    @Test func picksWithoutGettingInTheAppsWay() async throws {
        let coordinator = LocalServerPreviewWebContent.Coordinator()
        let webView = LocalServerPreviewWebContent.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            LocalServerPreviewWebContent.close(webView, coordinator: coordinator)
            window.contentView = nil
        }
        webView.loadHTMLString(app, baseURL: url("http://localhost:3000/settings"))
        #expect(try await answer(to: "String(window.ready)", in: webView, awaiting: "true") == "true")
        var picks: [(selection: DesignElementSelection, page: URL, image: NSImage?)] = []
        coordinator.onPick = { picks.append(($0, $1, $2)) }
        let cursor = "getComputedStyle(document.documentElement).cursor"

        _ = try await webView.evaluateJavaScript("gestures()")
        coordinator.setSelection(true, in: webView)
        coordinator.setSelection(false, in: webView)
        _ = try await webView.evaluateJavaScript("gestures()")
        #expect(try await webView.evaluateJavaScript("[presses, clicks]") as? [Int] == [14, 2])
        coordinator.setSelection(true, in: webView)
        #expect(try await answer(to: cursor, in: webView, awaiting: "crosshair") == "crosshair")
        try click(CGPoint(x: 200, y: 140), in: webView)
        #expect(await waitUntil { picks.count == 1 })
        _ = try await webView.evaluateJavaScript("gestures()")
        _ = try await webView.evaluateJavaScript("document.getElementById('agree').click()")
        try click(CGPoint(x: 500, y: 140), in: webView)
        #expect(await waitUntil { picks.count == 2 })

        let pick = try #require(picks.first)
        #expect(pick.selection == DesignElementSelection(selector: "#save", tag: "button", text: "Save",
                                                         rect: CGRect(x: 100, y: 100, width: 200, height: 80)))
        #expect(pick.page.path == "/settings")
        #expect(pick.image?.size == CGSize(width: 216, height: 96))
        #expect(picks.map(\.selection.selector) == ["#save", "#cancel"])
        #expect(try await webView.evaluateJavaScript("[presses, clicks]") as? [Int] == [14, 2])
        #expect(try await webView.evaluateJavaScript("document.getElementById('agree').checked") as? Bool == false)
        #expect(try await webView.evaluateJavaScript("""
            [typeof window.webkit?.messageHandlers?.codeStationDesignSelection,
             typeof window.__codeStationSetSelection]
            """) as? [String] == ["undefined", "undefined"])
        #expect(!webView.configuration.websiteDataStore.isPersistent)

        webView.loadHTMLString(app, baseURL: url("http://localhost:3000/billing"))
        let state = "location.pathname + ' ' + \(cursor)"
        #expect(try await answer(to: state, in: webView, awaiting: "/billing crosshair") == "/billing crosshair")
        #expect(try await webView.evaluateJavaScript("document.documentElement.hasAttribute('style')") as? Bool == false)
        _ = try await webView.evaluateJavaScript("""
            document.adoptedStyleSheets = [new CSSStyleSheet()];
            document.body.dispatchEvent(new PointerEvent("pointerover"));
            """)
        #expect(try await webView.evaluateJavaScript(cursor) as? String == "crosshair")
    }

    // Through the window, as a person clicks, so the page sees the click as trusted.
    private func click(_ point: CGPoint, in webView: WKWebView) throws {
        let window = try #require(webView.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: webView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

// The app in the pane is someone's work in progress, so the pane keeps it as it was left.
@MainActor
@Suite(.serialized)
struct LocalServerPreviewPageTests {
    // A session's pane with a running app on its Chat tab. The app is handed to the page
    // directly, so no server has to be running for it.
    @MainActor
    private final class Pane {
        // The bar runs along the top 42 points of the window, with its controls this far across.
        enum Control: CGFloat {
            case back = 28, forward = 66, address = 500, newPage = 820, picker = 858, openInBrowser = 896
        }

        let previews = LocalServerPreviewTabs()
        let preview: LocalServerPreview
        // Borderless, as in the other web tests: a window that can become key takes the
        // first click on the page for itself, and the app never sees it.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        private(set) var pageFocused = false
        private(set) var addressFocused = false
        private(set) var closed = false
        private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        private let store: ProjectStore
        private let scratch: ScratchDirectory
        private let session: ChatSession
        private let runner = SessionRunner(paths: [.codex: "/usr/bin/true"])
        private let settings: AppSettings
        private let shortcuts: ShortcutStore
        private let palette = GlobalCommandPaletteController()

        init(app: String = "<p>Start</p>",
             at address: URL = URL(string: "http://localhost:3000/settings")!) async throws {
            (store, scratch) = TestStore.make()
            let project = try TestStore.project(in: store)
            session = store.newSession(in: project.id, seed: .init(agent: .codex))
            let preferences = try #require(UserDefaults(suiteName: "preview-page-\(UUID().uuidString)"))
            settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences)
            shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
            previews.open(address)
            preview = try #require(previews.selected)
            preview.coordinator.loadedGeneration = preview.reloadGeneration
            preview.webView.loadHTMLString(app, baseURL: address)
            show(app: true)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1000, height: 800))
            window.center()
            window.orderFront(nil)
            try await load(preview)
        }

        func add() async throws -> LocalServerPreview {
            let address = url("http://localhost:3000/billing")
            previews.open(address, inNewPage: true)
            let page = try #require(previews.selected)
            page.coordinator.loadedGeneration = page.reloadGeneration
            page.webView.loadHTMLString("<p>Billing</p>", baseURL: address)
            try await load(page)
            return page
        }

        private func load(_ page: LocalServerPreview) async throws {
            #expect(await waitUntil { page.phase == .showing && !page.webView.isLoading })
            try await settle()
        }

        // The Chat tab with the app on it, or another tab with the app out of sight. It is
        // built from the pane's parts rather than the pane, which holds the page it shows.
        func show(app: Bool) {
            let previews = previews, session = session
            let focus = focus, addressFocus = addressFocus
            let close: () -> Void = { [weak self] in self?.closed = true }
            hosting.rootView = AnyView(Group {
                if app {
                    OnScreen(previews: previews) { page in
                        LocalServerPreviewPage(previews: previews, preview: page, session: session,
                                               placeholder: "Ask for a change", openPreview: { _ in false },
                                               pageFocused: focus, addressFocused: addressFocus, onClose: close)
                    }
                }
            }
            .environment(store)
            .environment(runner)
            .environment(settings)
            .environment(shortcuts)
            .environment(palette)
            .background(Theme.background)
            .appOverlays())
        }

        // Held weakly, since the page it goes to is held by this pane.
        private var focus: Binding<Bool> {
            Binding(get: { [weak self] in self?.pageFocused == true },
                    set: { [weak self] in self?.pageFocused = $0 })
        }

        private var addressFocus: Binding<Bool> {
            Binding(get: { [weak self] in self?.addressFocused == true },
                    set: { [weak self] in self?.addressFocused = $0 })
        }

        var conversation: DesignConversationDismissal.ObserverView? {
            func find(_ view: NSView) -> DesignConversationDismissal.ObserverView? {
                view as? DesignConversationDismissal.ObserverView ?? view.subviews.lazy.compactMap(find).first
            }
            return find(hosting.view)
        }

        var draft: SessionComposerStore.Draft { runner.composer.draft(session.id) }

        func click(_ point: CGPoint, holding modifiers: NSEvent.ModifierFlags = []) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }

        func press(_ characters: String, keyCode: UInt16) throws {
            window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)))
        }

        func click(_ control: Control) throws { try click(CGPoint(x: control.rawValue, y: 779)) }

        func click(page point: CGPoint) throws { try click(preview.webView.convert(point, to: nil)) }

        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            window.orderOut(nil)
            window.contentViewController = nil
            previews.closeAll()
            runner.stopAll()
        }
    }

    // Whichever page is on screen, as the session's pane shows it, so a switch brings in the
    // page that takes its place.
    private struct OnScreen: View {
        let previews: LocalServerPreviewTabs
        let page: (LocalServerPreview) -> LocalServerPreviewPage

        var body: some View {
            if let selected = previews.selected { page(selected) }
        }
    }

    @Test func keepsTheAppUntilItIsClosed() async throws {
        weak var released: WKWebView?
        do {
            let pane = try await Pane(app: "<input id='name'>")
            let page = pane.preview.webView
            released = page
            let name = "document.getElementById('name').value"
            _ = try await page.evaluateJavaScript("\(name) = 'Ada'")
            #expect(pane.conversation?.minimized == true)
            pane.window.makeFirstResponder(page)
            #expect(pane.pageFocused)

            pane.show(app: false)
            try await pane.settle()
            #expect(page.window == nil)
            #expect(!pane.pageFocused)
            pane.show(app: true)
            try await pane.settle()
            #expect(page.window === pane.window)
            #expect(try await page.evaluateJavaScript(name) as? String == "Ada")
            #expect(pane.preview.phase == .showing)
            _ = try await page.evaluateJavaScript("history.pushState(null, '', '/billing')")
            #expect(await waitUntil { pane.preview.address.path == "/billing" })
            pane.window.makeFirstResponder(page)
            #expect(pane.pageFocused)
            pane.preview.phase = .unreachable
            try await pane.settle()
            #expect(pane.window.firstResponder !== page)
            #expect(!pane.pageFocused)

            pane.close()
            // A closed page keeps its policy until it is gone, or WebKit hands a link it
            // cannot load to the system.
            #expect(page.navigationDelegate === pane.preview.coordinator)
        }
        #expect(await waitUntil { released == nil })
    }

    @Test func onlyAPersonsClickOpensTheBrowser() async throws {
        let pane = try await Pane(app: """
            <a id="docs" href="https://example.com/docs" \(box(0, 0))>Docs</a>
            <a id="help" href="https://example.com/help" target="_blank" \(box(0, 100))>Help</a>
            """)
        defer { pane.close() }
        var opened: [URL] = []
        pane.preview.coordinator.openInBrowser = { opened.append($0) }
        let docs = url("https://example.com/docs"), help = url("https://example.com/help")

        try pane.click(page: CGPoint(x: 100, y: 40))
        try pane.click(page: CGPoint(x: 100, y: 140))
        #expect(await waitUntil { opened == [docs, help] })
        #expect(pane.preview.phase == .showing)
        _ = try await pane.preview.webView.evaluateJavaScript("""
            Object.assign(document.createElement("a"), {href: "mailto:someone@example.com"}).click();
            document.getElementById("help").click();
            document.getElementById("docs").click();
            """)
        #expect(await waitUntil { pane.preview.phase == .left(docs) })
        #expect(opened == [docs, help])
        try pane.click(.openInBrowser)
        #expect(await waitUntil { pane.closed })
        #expect(opened == [docs, help, url("http://localhost:3000/settings")])
    }

    // A page that keeps sending files must not hold Code Station behind save panels, so for a
    // moment after a save is turned down only a person's click or a conversation link asks again.
    @Test func savesWhatTheAppSends() async throws {
        let server = FileServer(serving: "week,picks\n42,7\n", as: "report.csv")
        let port = try await server.start()
        defer { server.stop() }
        let report = "http://127.0.0.1:\(port)/report.csv"
        let pane = try await Pane(app: """
            <input id="name">
            <a id="export" href="data:text/csv,name%2Cteam" download="people.csv" \(box(0, 0))>Export</a>
            <iframe srcdoc="<a href='data:text/csv,team' download='teams.csv'
              style='position:absolute; left:0; top:0; width:200px; height:80px'>Export</a>"
              style="position:absolute; left:0; top:100px; width:300px; height:120px; border:0"></iframe>
            <a href="\(report)" \(box(0, 240))>Report</a>
            """)
        defer { pane.close() }
        let scratch = ScratchDirectory()
        var asked: [String] = []
        pane.preview.coordinator.saveDownload = { asked.append($0); return scratch.path($0) }
        let saved = { (name: String) in try? String(contentsOf: scratch.path(name), encoding: .utf8) }
        let page = pane.preview.webView
        let name = "document.getElementById('name').value", export = "document.getElementById('export').click()"
        _ = try await page.evaluateJavaScript("\(name) = 'Ada'")
        try "an earlier export".write(to: scratch.path("people.csv"), atomically: true, encoding: .utf8)

        let files = [(40.0, "people.csv", "name,team"), (140, "teams.csv", "team"),
                     (280, "report.csv", "week,picks\n42,7\n")]
        for (y, file, contents) in files {
            try pane.click(page: CGPoint(x: 100, y: y))
            #expect(await waitUntil { saved(file) == contents })
        }
        #expect(asked == ["people.csv", "teams.csv", "report.csv"])
        #expect(pane.preview.phase == .showing)
        #expect(pane.preview.address.path == "/settings")
        #expect(try await page.evaluateJavaScript(name) as? String == "Ada")
        let frame = "document.querySelector('iframe').contentDocument.body.innerText"
        #expect(try await page.evaluateJavaScript(frame) as? String == "Export")

        pane.preview.coordinator.saveDownload = { asked.append($0); return nil }
        _ = try await page.evaluateJavaScript(export)
        #expect(await waitUntil { asked.count == 4 })
        _ = try await page.evaluateJavaScript("\(export); \(export)")
        _ = try await page.evaluateJavaScript("location.href = '\(report)'")
        try await pane.settle()
        #expect(asked.count == 4)
        try pane.click(page: CGPoint(x: 100, y: 40))
        #expect(await waitUntil { asked.count == 5 })
        try await pane.settle()
        #expect(asked.count == 5)
        #expect(pane.preview.phase == .showing)
        try pane.click(page: CGPoint(x: 100, y: 280))
        #expect(await waitUntil { asked.count == 6 })
        pane.preview.open(url(report))
        #expect(await waitUntil { asked.count == 7 })
        #expect(await waitUntil { pane.preview.address.path == "/settings" })
        pane.preview.coordinator.declinedAt = .now - .seconds(2)
        _ = try await page.evaluateJavaScript(export)
        #expect(await waitUntil { asked.count == 8 })
    }

    // A press while picking is a pick on its way to the composer, so it leaves the panel open.
    // The pane's clicks skip the monitor that watches for presses, so the panel is handed one.
    @Test func aPickOpensTheConversationWithTheElementInIt() async throws {
        let pane = try await Pane(app: "<button id='save' \(box(100, 100))>Save</button>")
        defer { pane.close() }
        let conversation = try #require(pane.conversation)
        let save = pane.preview.webView.convert(CGPoint(x: 200, y: 140), to: nil)
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: save,
            modifierFlags: [], timestamp: 0, windowNumber: pane.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        try pane.click(.picker)
        try await pane.settle()
        #expect(!conversation.minimized)
        #expect(conversation.handle(press, frontmost: pane.window) === press)
        try await pane.settle()
        #expect(!conversation.minimized)
        // A message over the page rests the picker, so the same press shrinks the panel, and
        // when the page comes back the pick has to bring the conversation back by itself.
        pane.preview.phase = .unreachable
        try await pane.settle()
        _ = conversation.handle(press, frontmost: pane.window)
        try await pane.settle()
        #expect(conversation.minimized)
        pane.preview.phase = .showing
        try await pane.settle()
        try pane.click(save)
        #expect(await waitUntil { !pane.draft.attachments.isEmpty })
        let crop = try #require(pane.draft.attachments.first)
        defer { try? FileManager.default.removeItem(at: crop.url) }
        try await pane.settle()

        #expect(crop.name.hasPrefix("selection-"))
        #expect(!conversation.minimized)
        let composer = try #require(pane.window.firstResponder as? NSTextView)
        #expect(composer.isEditable)
        #expect(composer.string == "Refine \"Save\" at `#save` on `/settings`. ")
    }

    @Test func typingAnAddressLoadsIt() async throws {
        let server = FileServer(serving: "Next")
        let port = try await server.start()
        defer { server.stop() }
        let pane = try await Pane()
        defer { pane.close() }

        try pane.click(.address)
        #expect(await waitUntil { pane.window.firstResponder is NSTextView })
        let field = try #require(pane.window.firstResponder as? NSTextView)
        #expect(field.string == "http://localhost:3000/settings")
        #expect(field.selectedRange() == NSRange(location: 0, length: field.string.utf16.count))
        #expect(pane.addressFocused)
        field.insertText("http://", replacementRange: field.selectedRange())
        try pane.press("\r", keyCode: 36)
        try await pane.settle()
        #expect(pane.window.firstResponder === field)
        #expect(field.string == "http://")
        #expect(pane.addressFocused)
        field.insertText("localhost:5173/elsewhere", replacementRange: field.selectedRange())
        try pane.press("\u{1b}", keyCode: 53)
        #expect(await waitUntil { !pane.addressFocused })
        #expect(pane.preview.address.absoluteString == "http://localhost:3000/settings")
        #expect(pane.preview.reloadGeneration == 1)
        #expect(pane.pageFocused)

        try pane.click(.address)
        #expect(await waitUntil { pane.window.firstResponder is NSTextView })
        let again = try #require(pane.window.firstResponder as? NSTextView)
        again.insertText("localhost:\(port)/next", replacementRange: again.selectedRange())
        try pane.press("\r", keyCode: 36)
        #expect(try await answer(to: "document.body.innerText", in: pane.preview.webView, awaiting: "Next") == "Next")
        #expect(pane.preview.address.absoluteString == "http://localhost:\(port)/next")
        #expect(pane.pageFocused)
        #expect(!pane.addressFocused)
    }

    @Test func goesBackAndForwardThroughThePagesVisited() async throws {
        let server = FileServer(serving: """
            <button onclick="history.pushState({}, '', '/settings')" \(box(0, 0))>Settings</button>
            """)
        let port = try await server.start()
        defer { server.stop() }
        let pane = try await Pane()
        defer { pane.close() }
        let page = pane.preview.webView
        let app = url("http://localhost:\(port)/")
        pane.preview.open(app)
        #expect(try await answer(to: "document.body.innerText", in: page, awaiting: "Settings") == "Settings")

        try pane.click(page: CGPoint(x: 100, y: 40))
        #expect(await waitUntil { pane.preview.address.path == "/settings" && pane.preview.canGoBack })
        try pane.click(.back)
        #expect(await waitUntil { pane.preview.address == app && pane.preview.canGoForward })
        try pane.click(.forward)
        #expect(await waitUntil { pane.preview.address.path == "/settings" && !pane.preview.canGoForward })
        // As after a load to a server that is not running: the address names it, and the page
        // that was there stays under the message.
        pane.preview.open(url("http://localhost:5173/"))
        pane.preview.coordinator.loadedGeneration = pane.preview.reloadGeneration
        pane.preview.phase = .unreachable
        try await pane.settle()
        #expect(pane.preview.canGoBack)
        try pane.click(.back)
        try await pane.settle()

        #expect(pane.preview.phase == .showing)
        #expect(pane.preview.address == url("http://localhost:\(port)/settings"))
        #expect(!pane.preview.canGoForward)
        #expect(try await page.evaluateJavaScript("document.body.innerText") as? String == "Settings")
    }

    // Nobody is looking at a page off screen, so it hands the keyboard, picking and an address
    // being typed to the page on screen, and a file it sends by itself is not offered.
    @Test func keepsEachPagesWorkWhenSwitchingBetweenThem() async throws {
        let pane = try await Pane(app: "<script>document.cookie = 'session=signed-in; path=/'</script>")
        defer { pane.close() }
        let home = pane.preview
        let other = try await pane.add()
        var asked: [String] = []
        for page in [home, other] { page.coordinator.saveDownload = { asked.append($0); return nil } }
        let export = "Object.assign(document.createElement('a'), "
            + "{href: 'data:text/csv,name', download: 'export.csv'}).click(); true"
        let cursor = "getComputedStyle(document.documentElement).cursor"
        _ = try await home.webView.evaluateJavaScript("window.work = 'home draft'")
        _ = try await other.webView.evaluateJavaScript("window.work = 'other draft'")
        let generations = (home.reloadGeneration, other.reloadGeneration)
        let top = other.webView.convert(other.webView.bounds, to: nil).maxY

        // The first tab, the home page's, is in the strip between the bar and the page.
        try pane.click(CGPoint(x: 20, y: (top + 800 - 42) / 2))
        #expect(await waitUntil { pane.previews.selected === home })
        try await pane.settle()
        #expect(home.phase == .showing)
        #expect(home.webView.window != nil)
        #expect(other.webView.window == nil)
        #expect(try await home.webView.evaluateJavaScript("window.work") as? String == "home draft")
        #expect(try await other.webView.evaluateJavaScript("window.work") as? String == "other draft")
        try #require((home.reloadGeneration, other.reloadGeneration) == generations)
        #expect(try await other.webView.evaluateJavaScript("document.cookie") as? String == "session=signed-in")

        pane.window.makeFirstResponder(home.webView)
        #expect(pane.pageFocused)
        pane.previews.select(other)
        try await pane.settle()
        #expect(!pane.pageFocused)
        _ = try await home.webView.evaluateJavaScript(export)
        try await pane.settle()
        #expect(asked.isEmpty)
        _ = try await other.webView.evaluateJavaScript(export)
        #expect(await waitUntil { asked == ["export.csv"] })
        try pane.click(.picker)
        #expect(try await answer(to: cursor, in: other.webView, awaiting: "crosshair") == "crosshair")
        try pane.click(.address)
        #expect(await waitUntil { pane.window.firstResponder is NSTextView })
        let field = try #require(pane.window.firstResponder as? NSTextView)
        field.insertText("/team", replacementRange: field.selectedRange())
        pane.previews.select(home)
        try await pane.settle()
        #expect(field.string == "http://localhost:3000/settings")
        #expect(try await answer(to: cursor, in: home.webView, awaiting: "crosshair") == "crosshair")
        #expect(try await answer(to: cursor, in: other.webView, awaiting: "auto") == "auto")
    }

    @Test func anotherPageOpensAtTheAppsRootAndClosesAlone() async throws {
        let server = FileServer(serving: "<p>Home</p>")
        let port = try await server.start()
        defer { server.stop() }
        let pane = try await Pane(at: url("http://localhost:\(port)/settings"))
        defer { pane.close() }
        weak var released: WKWebView?
        do {
            let other = try await pane.add()
            released = other.webView
            pane.previews.close(other)
        }
        try await pane.settle()
        #expect(pane.previews.selected === pane.preview)
        #expect(await waitUntil { released == nil })

        try pane.click(.newPage)
        #expect(await waitUntil { pane.previews.pages.count == 2 })
        let root = try #require(pane.previews.selected)
        #expect(root.address.absoluteString == "http://localhost:\(port)/")
        #expect(await waitUntil { (pane.window.firstResponder as? NSTextView)?.string == "http://localhost:\(port)/" })
        var opened: [URL] = []
        root.coordinator.openInBrowser = { opened.append($0) }
        try pane.click(.openInBrowser)
        #expect(await waitUntil { pane.previews.pages.count == 1 })
        #expect(opened.map(\.absoluteString) == ["http://localhost:\(port)/"])
        #expect(pane.previews.selected === pane.preview)
        #expect(!pane.closed)
    }

    // A page the app opens beside itself at a person's press is another page, or goes to the
    // browser when it is elsewhere, and the page it came from stays. WebKit stops the rest.
    @Test func aPageTheAppOpensBesideItselfOpensAsAnotherPage() async throws {
        let server = FileServer(serving: "<p>Page</p>")
        let port = try await server.start()
        defer { server.stop() }
        let pane = try await Pane(app: """
            <a id="docs" href="/docs" target="_blank" \(box(0, 0))>Docs</a>
            <button onclick="document.getElementById('docs').click()" \(box(0, 100))>Docs</button>
            <button onclick="window.open('/report')" \(box(0, 200))>Report</button>
            <a href="/billing" \(box(0, 300))>Billing</a>
            <button onclick="window.open('https://example.com/docs')" \(box(0, 400))>Elsewhere</button>
            <a id="later" href="/later" target="_blank"></a>
            <script>setTimeout(() => document.getElementById("later").click()); window.open("/popup");</script>
            """, at: url("http://localhost:\(port)/settings"))
        defer { pane.close() }
        var opened: [URL] = []
        pane.preview.coordinator.openInBrowser = { opened.append($0) }
        let page = pane.preview.webView
        try await pane.settle()
        #expect(pane.previews.pages.count == 1)

        let links: [(y: CGFloat, path: String, holding: NSEvent.ModifierFlags)] = [
            (40, "/docs", []), (140, "/docs", []), (240, "/report", []), (340, "/billing", .command),
        ]
        for link in links {
            let pages = pane.previews.pages.count
            try pane.click(page.convert(CGPoint(x: 100, y: link.y), to: nil), holding: link.holding)
            #expect(await waitUntil { pane.previews.pages.count == pages + 1 })
            #expect(pane.previews.selected?.address.path == link.path)
            pane.previews.select(pane.preview)
            try await pane.settle()
        }
        try pane.click(page: CGPoint(x: 100, y: 440))

        #expect(await waitUntil { opened == [url("https://example.com/docs")] })
        #expect(pane.previews.pages.count == 5)
        #expect(pane.preview.address.path == "/settings")
    }
}

// The page answers in its own time, so it is asked again until the answer arrives.
@MainActor
private func answer(to script: String, in webView: WKWebView,
                    awaiting expected: String) async throws -> String? {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline,
          (try? await webView.evaluateJavaScript(script)) as? String != expected {
        try await Task.sleep(for: .milliseconds(30))
    }
    return (try? await webView.evaluateJavaScript(script)) as? String
}

// A server on this machine that answers every request the same way: with one file, sent
// the way a dev server sends an export, or with one page.
private final class FileServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local-server-preview.file-server")
    private let listener = HTTPListener()
    private let reply: Data

    init(serving body: String, as file: String? = nil) {
        let type = file.map { "text/csv\r\nContent-Disposition: attachment; filename=\($0)" }
        reply = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(type ?? "text/html; charset=utf-8")\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }


    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let bound = try NWListener(using: parameters, on: .any)
        return try await withCheckedThrowingContinuation { ready in
            queue.async {
                self.listener.expect(ready)
                self.listener.start(bound, on: self.queue) { connection in
                    connection.start(queue: self.queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        connection.send(content: self.reply, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } failed: { error in
                    self.listener.answer(.failure(error))
                }
            }
        }
    }

    func stop() { queue.async { self.listener.cancel() } }
}
