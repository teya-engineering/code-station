import AppKit
import SwiftUI
import WebKit
import CodeStationCore

@MainActor
@Observable
final class LocalServerPreview: Identifiable {
    enum Phase: Equatable {
        case opening, showing, unreachable, failed(String), noPage, stopped, left(URL)
        indirect case elsewhere(URL, over: Phase)
    }

    private(set) var address: URL
    private(set) var reloadGeneration = 0
    var phase = Phase.opening
    private var pageBehind = false
    private var pageAhead = false

    let id = UUID()
    // Held here rather than in the view, so the page survives a switch to another tab.
    @ObservationIgnored let coordinator = LocalServerPreviewWebContent.Coordinator()
    @ObservationIgnored private var madeWebView: WKWebView?
    // Kept off disk, so nothing a running app stores outlives the session's pane.
    @ObservationIgnored private let dataStore: WKWebsiteDataStore

    init(opening address: URL, dataStore: WKWebsiteDataStore = .nonPersistent()) {
        self.address = address
        self.dataStore = dataStore
        reload()
    }

    var webView: WKWebView {
        if let madeWebView { return madeWebView }
        coordinator.onAddress = { [weak self] in self?.follow($0) }
        coordinator.onPhase = { [weak self] in self?.pagePhase = $0 }
        coordinator.onLoaded = { [weak self] in self?.finishLoading(hasPage: $0) }
        coordinator.onHistory = { [weak self] behind, ahead in
            self?.pageBehind = behind
            self?.pageAhead = ahead
        }
        let webView = LocalServerPreviewWebContent.makeWebView(coordinator: coordinator,
                                                               dataStore: dataStore)
        madeWebView = webView
        return webView
    }

    func open(_ url: URL) {
        address = url
        reload()
    }

    func open(typed text: String) -> Bool {
        guard let url = Self.address(text, on: address) else { return false }
        if TranscriptLink.isLocalServer(url) {
            open(url)
        } else {
            phase = .elsewhere(url, over: pagePhase)
        }
        return true
    }

    func stay() { phase = pagePhase }

    private var pagePhase: Phase {
        get { if case .elsewhere(_, let page) = phase { page } else { phase } }
        set {
            if case .elsewhere(let url, _) = phase {
                phase = .elsewhere(url, over: newValue)
            } else {
                phase = newValue
            }
        }
    }

    func reload() {
        phase = pagePhase == .showing ? .showing : .opening
        reloadGeneration += 1
    }

    // A failed or held-back load never joined the history, so Back first returns to the
    // page under its message.
    var canGoBack: Bool {
        switch phase {
        case .elsewhere: true
        case .unreachable, .failed, .left: shownPage != nil
        case .opening, .showing, .noPage, .stopped: pageBehind
        }
    }

    // The page the web view last showed, read from its history: its url can briefly hold
    // the target of a redirect that is about to be turned away.
    private var shownPage: URL? { madeWebView?.backForwardList.currentItem?.url }

    var canGoForward: Bool { phase == .showing && pageAhead }

    func goBack() {
        switch phase {
        case .elsewhere:
            stay()
        case .unreachable, .failed, .left:
            guard let shownPage else { return }
            phase = .showing
            follow(shownPage)
        case .opening, .showing, .noPage, .stopped:
            madeWebView?.goBack()
        }
    }

    func goForward() { madeWebView?.goForward() }

    // A failed load sends the web view back to the page it had, but the address stays on
    // the one that failed, so Reload tries it again.
    func follow(_ url: URL) {
        switch pagePhase {
        case .unreachable, .failed, .noPage: return
        case .opening, .showing, .stopped, .left, .elsewhere: break
        }
        if url != address { address = url }
    }

    // Nothing arrives when a load only moves within the page, so one that ends while
    // opening has left that page showing. No page means a download or another app's link.
    func finishLoading(hasPage: Bool) {
        guard pagePhase == .opening else { return }
        pagePhase = hasPage ? .showing : .noPage
    }

    // Stopped at once, since letting a web view go can take a moment and its timers and
    // its dev server's reload socket run until then.
    func close() {
        guard let madeWebView else { return }
        LocalServerPreviewWebContent.close(madeWebView, coordinator: coordinator)
    }

    static func draft(_ text: String, adding selection: DesignElementSelection,
                      on address: URL) -> String {
        let place = "`\(selection.selector)` on `\(path(address))`"
        let reference = selection.reference(at: place)
        if text.isEmpty { return reference }
        return text.contains(place) ? text : text + "\n\n" + reference
    }

    static func label(for url: URL) -> String {
        let path = Self.path(url)
        return path == "/" ? server(url) : server(url) + path
    }

    // Read from the address as written, since a parsed host can lose the brackets around
    // an IPv6 address and its port would then read as part of it.
    static func server(_ url: URL) -> String {
        let authority = url.absoluteString
            .drop(while: { $0 != "/" }).dropFirst(2)
            .prefix(while: { !"/?#".contains($0) })
        return String(authority.split(separator: "@").last ?? authority)
    }

    // Any query is left out, since it can carry tokens.
    static func path(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let fragment = url.fragment, fragment.hasPrefix("/") else { return path }
        return path + "#" + fragment.prefix(while: { $0 != "?" })
    }

    // A bare port keeps the page's host name, as a sign-in is kept under one name only.
    // Http is the default, as a dev server seldom has a certificate.
    static func address(_ typed: String, on page: URL?) -> URL? {
        var text = typed.trimmed
        let rest = text.hasPrefix(":") ? text.dropFirst() : Substring(text)
        let head = rest.prefix(while: { !"/?#".contains($0) })
        if let port = Int(head), (1...65_535).contains(port) {
            let name = page.flatMap {
                TranscriptLink.isLocalServer($0)
                    ? URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedHost
                    : nil
            }
            text = "\(name ?? "localhost"):\(port)" + rest.dropFirst(head.count)
        }
        let hasScheme = text.range(of: "://").map {
            !text[..<$0.lowerBound].contains(where: { "/?#".contains($0) })
        } ?? false
        let written = text.hasPrefix("/") || text.hasPrefix("#")
            ? page.flatMap { URL(string: text, relativeTo: $0)?.absoluteURL }
            : URL(string: hasScheme ? text : "http://" + text)
        guard let written, var parts = URLComponents(url: written, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        if !hasScheme, let page, page.scheme == "https", parts.url.map(server) == server(page) {
            parts.scheme = "https"
        }
        guard let url = parts.url, ["http", "https"].contains(url.scheme ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

@MainActor
@Observable
final class LocalServerPreviewTabs {
    private(set) var pages: [LocalServerPreview] = []
    private(set) var selectedID: UUID?
    private(set) var isOpen = false
    @ObservationIgnored private lazy var dataStore = WKWebsiteDataStore.nonPersistent()

    var selected: LocalServerPreview? { pages.first { $0.id == selectedID } }

    func open(_ url: URL, inNewPage: Bool = false) {
        let label = LocalServerPreview.label(for: url)
        let shows = { (page: LocalServerPreview) in
            LocalServerPreview.label(for: page.address) == label
        }
        let showing = selected.flatMap { shows($0) ? $0 : nil } ?? pages.first(where: shows)
        if !inNewPage, let page = showing ?? selected {
            page.open(url)
            selectedID = page.id
        } else {
            let page = LocalServerPreview(opening: url, dataStore: dataStore)
            page.coordinator.onNewPage = { [weak self] in self?.open($0, inNewPage: true) }
            pages.append(page)
            selectedID = page.id
        }
        isOpen = true
    }

    func openAnotherPage() {
        guard let address = selected?.address,
              let root = URL(string: "/", relativeTo: address)?.absoluteURL else { return }
        open(root, inNewPage: true)
    }

    func select(_ page: LocalServerPreview) { selectedID = page.id }

    func close(_ page: LocalServerPreview) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        page.close()
        pages.remove(at: index)
        if pages.isEmpty {
            selectedID = nil
            isOpen = false
        } else if selectedID == page.id {
            selectedID = pages[min(index, pages.count - 1)].id
        }
    }

    func show() { isOpen = !pages.isEmpty }
    func hide() { isOpen = false }

    func closeAll() {
        pages.forEach { $0.close() }
        pages = []
        selectedID = nil
        isOpen = false
    }

}

struct LocalServerPreviewPage: View {
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let previews: LocalServerPreviewTabs
    let preview: LocalServerPreview
    let session: ChatSession
    let placeholder: String
    let openPreview: (URL) -> Bool
    var openChange: (String) -> Void = { _ in }
    var runInShell: (String) -> Void = { _ in }
    var showInExplorer: (URL) -> Bool = { _ in false }
    @Binding var pageFocused: Bool
    @Binding var addressFocused: Bool
    let onClose: () -> Void

    @State private var conversationMinimized = true
    @State private var conversationExpanded = false
    @State private var composerFocused = false
    @State private var promptSentAt: Date?
    @State private var selectionEnabled = false
    @State private var editingAddress = false
    @State private var typedAddress = ""
    @State private var barWidth: CGFloat = .infinity
    @State private var scrolledPageID: UUID?
    @FocusState private var addressFieldFocused: Bool
    // A monitor sees these keys before the page and before the window's Back and Forward.
    @State private var addressMonitor = WindowKeyMonitor(.command, "l")
    @State private var backMonitor = WindowKeyMonitor(.command, "[")
    @State private var forwardMonitor = WindowKeyMonitor(.command, "]")

    private var picking: Bool { selectionEnabled && preview.phase == .showing }

    var body: some View {
        VStack(spacing: 0) {
            bar
            pageStrip
            GeometryReader { geometry in
                // An overlay would rebuild the composer when a message replaces the page.
                ZStack(alignment: .bottom) {
                    page(in: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    DesignConversation(session: session, size: geometry.size,
                                       conversationExpanded: $conversationExpanded,
                                       conversationMinimized: $conversationMinimized,
                                       composerFocused: $composerFocused,
                                       promptSentAt: $promptSentAt,
                                       designEmpty: false, selectionEnabled: picking,
                                       placeholder: placeholder,
                                       showsDesignAmbition: false,
                                       openPreview: openPreview,
                                       openChange: openChange,
                                       runInShell: runInShell,
                                       showInExplorer: showInExplorer,
                                       pagesTranscript: true)
                        .padding(DesignConversationLayout.inset(in: geometry.size))
                }
            }
        }
        .background(Theme.background)
        .background(WindowAnchor(monitor: addressMonitor))
        .background(WindowAnchor(monitor: backMonitor))
        .background(WindowAnchor(monitor: forwardMonitor))
        .onChange(of: dialogs.current == nil, initial: true) { _, free in
            if free { startMonitors() } else { stopMonitors() }
        }
        // The monitors capture the page they started with, so they start again with the new one.
        .onChange(of: preview.id) {
            if dialogs.current == nil { startMonitors() }
            if editingAddress { typedAddress = preview.address.absoluteString }
        }
        .onChange(of: addressFieldFocused) { _, focused in
            addressFocused = focused
            if !focused { editingAddress = false }
        }
        // A stale flag would keep Escape from stopping the turn, so it is cleared here.
        .onDisappear {
            pageFocused = false
            addressFocused = false
            stopMonitors()
        }
    }

    // Consumed even with nowhere to go, as the window's own Back would switch sessions.
    private func startMonitors() {
        addressMonitor.start {
            editAddress()
            return true
        }
        backMonitor.start { navigate(preview.canGoBack) { preview.goBack() } }
        forwardMonitor.start { navigate(preview.canGoForward) { preview.goForward() } }
    }

    private func navigate(_ possible: Bool, _ go: () -> Void) -> Bool {
        guard pageFocused || addressFocused else { return false }
        if possible {
            go()
            if editingAddress { leaveAddress() }
        }
        return true
    }

    private func stopMonitors() {
        for monitor in [addressMonitor, backMonitor, forwardMonitor] { monitor.stop() }
    }

    private func page(in size: CGSize) -> some View {
        let showing = preview.phase == .showing
        let room = messageRoom(in: size)
        return ZStack {
            LocalServerPreviewWebContent(preview: preview, address: preview.address,
                                         reloadGeneration: preview.reloadGeneration,
                                         showing: showing,
                                         selectionEnabled: picking,
                                         isFocused: $pageFocused,
                                         onPick: pick)
                // A mount keeps its first coordinator, so each page needs its own.
                .id(preview.id)
                .background(Color.white)
                // The page stays built under a message, so it and its sign-in
                // survive a failed reload.
                .opacity(showing ? 1 : 0)
                .allowsHitTesting(showing)
                .accessibilityHidden(!showing)
            if !showing {
                message
                    .padding(.bottom, room)
                    .clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: room)
                    .background(Theme.sunken)
            }
        }
    }

    private static let roomForHistory: CGFloat = 400

    private var bar: some View {
        HStack(spacing: 10) {
            if barWidth >= Self.roomForHistory {
                barButton("chevron.left", help: "Go back", disabled: !preview.canGoBack) {
                    preview.goBack()
                }
                barButton("chevron.right", help: "Go forward", disabled: !preview.canGoForward) {
                    preview.goForward()
                }
            }
            addressField
                .frame(maxWidth: .infinity, alignment: .leading)
            barButton("plus", help: "Open another page") {
                previews.openAnotherPage()
                editAddress()
            }
            if preview.phase == .showing {
                GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                            active: selectionEnabled, tint: Theme.accent) {
                    selectionEnabled.toggle()
                    if selectionEnabled { conversationMinimized = false }
                }
                .appTooltip(selectionEnabled
                    ? "Stop selecting page elements"
                    : "Select an element to refine")
                .accessibilityLabel("Select an element to refine")
            }
            barButton("arrow.up.right", help: "Open in browser") { openInBrowser(preview.address) }
            barButton("xmark", help: "Hide preview", action: onClose)
            barButton("arrow.clockwise", help: "Reload page") { preview.reload() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .canvasBar()
    }

    private func barButton(_ icon: String, help: String, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        GlyphButton(icon: icon, side: 28, tint: Theme.accent.opacity(disabled ? 0.3 : 1),
                    action: action)
            .disabled(disabled)
            .appTooltip(help)
            .accessibilityLabel(help)
    }

    // Typed text is kept apart from the address, so a navigation never overwrites it.
    @ViewBuilder private var addressField: some View {
        if editingAddress {
            addressSurface {
                TextField("Address or path", text: $typedAddress)
                    .textFieldStyle(.plain)
                    .font(.mono(11))
                    .focused($addressFieldFocused)
                    .onSubmit { if preview.open(typed: typedAddress) { leaveAddress() } }
                    .onExitCommand(perform: leaveAddress)
            }
            .onAppear { $addressFieldFocused.request() }
        } else {
            Button(action: editAddress) {
                addressSurface {
                    Text(LocalServerPreview.label(for: preview.address))
                        .font(.mono(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .appTooltip(preview.address.absoluteString)
            .accessibilityLabel("Address")
            .accessibilityValue(LocalServerPreview.label(for: preview.address))
        }
    }

    private func addressSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .fieldSurface(cornerRadius: 7)
    }

    // Just after a page opens, this view still holds the old one, so the selection is read.
    private func editAddress() {
        guard let address = previews.selected?.address, !editingAddress else { return }
        // An expanded conversation would take Escape from the field.
        conversationExpanded = false
        typedAddress = address.absoluteString
        editingAddress = true
    }

    private func leaveAddress() {
        editingAddress = false
        guard preview.phase == .showing else { return }
        preview.webView.window?.makeFirstResponder(preview.webView)
    }

    @ViewBuilder private var message: some View {
        let address = preview.address
        let server = LocalServerPreview.server(address)
        switch preview.phase {
        case .showing:
            EmptyView()
        case .opening:
            PaneMessage(icon: "globe", title: "Opening \(server)",
                        detail: "It appears here as soon as the server answers.")
        case .unreachable:
            PaneMessage(icon: "bolt.horizontal", title: "Nothing is running at \(server)",
                        detail: "Start the server, then reload.") { reloadButton }
        case .failed(let reason):
            PaneMessage(icon: "exclamationmark.triangle", title: "The page could not load",
                        detail: reason) { reloadButton }
        case .noPage:
            PaneMessage(icon: "doc",
                        title: "There is no page at \(LocalServerPreview.label(for: address))",
                        detail: "It leads to a file or another app rather than to a page.") {
                browserButton(address)
            }
        case .stopped:
            PaneMessage(icon: "exclamationmark.triangle", title: "The preview stopped",
                        detail: "Reload to try again.") { reloadButton }
        case .left(let url):
            PaneMessage(icon: "arrow.up.right.square",
                        title: "The app went to \(url.host ?? url.absoluteString)",
                        detail: "The preview only shows pages served from this machine.") {
                browserButton(url)
            }
        case .elsewhere(let url, _):
            PaneMessage(icon: "arrow.up.right.square",
                        title: "The preview does not open \(url.host ?? url.absoluteString)",
                        detail: "It only shows pages served from this machine.") {
                // Only this address goes to the browser, so the app's page stays open.
                HStack(spacing: 8) {
                    ActionButton(title: "Back to the app", tone: .outlined,
                                 icon: "arrow.uturn.backward") {
                        preview.stay()
                    }
                    ActionButton(title: "Open in browser", tone: .outlined,
                                 icon: "arrow.up.right") {
                        preview.coordinator.openInBrowser(url)
                        preview.stay()
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func messageRoom(in size: CGSize) -> CGFloat {
        guard !conversationExpanded else { return 0 }
        let conversation = DesignConversationLayout.size(in: size, expanded: false,
                                                         minimized: conversationMinimized)
        return conversation.height + DesignConversationLayout.inset(in: size)
    }

    private var reloadButton: some View {
        ActionButton(title: "Reload", tone: .outlined, icon: "arrow.clockwise") {
            preview.reload()
        }
        .padding(.top, 4)
    }

    private func browserButton(_ url: URL) -> some View {
        ActionButton(title: "Open in browser", tone: .outlined, icon: "arrow.up.right") {
            openInBrowser(url)
        }
        .padding(.top, 4)
    }

    private func openInBrowser(_ url: URL) {
        preview.coordinator.openInBrowser(url)
        previews.close(preview)
        if !previews.isOpen { onClose() }
    }

    @ViewBuilder private var pageStrip: some View {
        if previews.pages.count > 1 {
            let servers = Set(previews.pages.map { LocalServerPreview.server($0.address) })
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(previews.pages) { page in
                        pageTab(page, spansServers: servers.count > 1)
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .scrollPosition(id: $scrolledPageID, anchor: .center)
            .onChange(of: previews.selectedID, initial: true) { _, selected in
                scrolledPageID = selected
            }
            .background(Theme.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private func pageTab(_ page: LocalServerPreview, spansServers: Bool) -> some View {
        let selected = page.id == preview.id
        let label = spansServers
            ? LocalServerPreview.label(for: page.address) : LocalServerPreview.path(page.address)
        return HStack(spacing: 0) {
            Button { previews.select(page) } label: {
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip(page.address.absoluteString)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { previews.close(page) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("Close page")
            .accessibilityLabel("Close \(label)")
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.card : .clear)
                .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1, y: 0.5))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : .clear))
        .hoverLift()
    }

    // The page keeps this closure, so it captures the composer rather than this view,
    // which holds the page: SwiftUI updates a closing mount once more, leaving a cycle.
    private var pick: (DesignElementSelection, URL, NSImage?) -> Void {
        let composer = runner.composer, sessionID = session.id
        let minimized = $conversationMinimized, focused = $composerFocused
        return { selection, page, image in
            composer.editDraft(sessionID) {
                $0.text = LocalServerPreview.draft($0.text, adding: selection, on: page)
            }
            if let image, let attachment = Attachments.fromImage(image, prefix: "selection") {
                composer.attach([attachment], to: sessionID)
            }
            minimized.wrappedValue = false
            focused.wrappedValue = true
        }
    }
}

// The page belongs to the preview, so mounting moves it into whichever container is shown.
struct LocalServerPreviewWebContent: NSViewRepresentable {
    let preview: LocalServerPreview
    let address: URL
    let reloadGeneration: Int
    let showing: Bool
    let selectionEnabled: Bool
    @Binding var isFocused: Bool
    let onPick: (DesignElementSelection, URL, NSImage?) -> Void

    func makeCoordinator() -> Coordinator { preview.coordinator }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        if preview.webView.superview !== container { install(in: container) }
        container.onFocusChange = { focused in if isFocused != focused { isFocused = focused } }
        if !showing { container.letGoOfKeyboard() }
        context.coordinator.onPick = onPick
        context.coordinator.setSelection(selectionEnabled, in: preview.webView)
        guard context.coordinator.loadedGeneration != reloadGeneration else { return }
        context.coordinator.loadedGeneration = reloadGeneration
        context.coordinator.declinedAt = nil
        preview.webView.load(URLRequest(url: address))
    }

    // A web view already moved to another container is left as that container set it.
    static func dismantleNSView(_ container: Container, coordinator: Coordinator) {
        guard let webView = container.subviews.first as? WKWebView else { return }
        coordinator.setSelection(false, in: webView)
    }

    private func install(in container: NSView) {
        let webView = preview.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    static func makeWebView(coordinator: Coordinator,
                            dataStore: WKWebsiteDataStore = .nonPersistent()) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The picker runs in a world the page's scripts cannot reach, and is added
        // before them so its press listeners run ahead of the app's.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient,
                                                 name: DesignWebContent.Coordinator.messageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.pickerScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        coordinator.observations = [
            // The address can change during a SwiftUI update, so it is passed on later.
            webView.observe(\.url) { [weak coordinator] webView, _ in
                MainActor.assumeIsolated {
                    guard let url = webView.url, TranscriptLink.isLocalServer(url) else { return }
                    Task { @MainActor in coordinator?.onAddress(url) }
                }
            },
            // A link to an anchor on the same page ends its load without a commit.
            webView.observe(\.isLoading) { [weak coordinator] webView, _ in
                Task { @MainActor in
                    if !webView.isLoading { coordinator?.onLoaded(webView.url != nil) }
                }
            },
            // Routing by script loads nothing, so history is watched rather than read.
            webView.observe(\.canGoBack) { [weak coordinator] webView, _ in
                Task { @MainActor in
                    coordinator?.onHistory(webView.canGoBack, webView.canGoForward)
                }
            },
            webView.observe(\.canGoForward) { [weak coordinator] webView, _ in
                Task { @MainActor in
                    coordinator?.onHistory(webView.canGoBack, webView.canGoForward)
                }
            },
        ]
        return webView
    }

    // The navigation delegate stays until the page is gone: without one, WebKit hands
    // any link it cannot load to the system, clicked or not.
    static func close(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: DesignWebContent.Coordinator.messageName, contentWorld: .defaultClient)
        coordinator.observations = []
    }

    final class Container: NSView {
        var onFocusChange: ((Bool) -> Void)?
        private var responderObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            responderObservation = window?.observe(\.firstResponder,
                                                   options: [.old, .new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let gained = self.holds(change.newValue ?? nil)
                    if gained || self.holds(change.oldValue ?? nil) { self.onFocusChange?(gained) }
                }
            }
        }

        // SwiftUI cannot take a focus change mid-update, so it waits and checks again.
        func letGoOfKeyboard() {
            guard holds(window?.firstResponder) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.holds(self.window?.firstResponder) else { return }
                self.window?.makeFirstResponder(nil)
            }
        }

        private func holds(_ responder: NSResponder?) -> Bool {
            (responder as? NSView)?.isDescendant(of: self) == true
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                             WKScriptMessageHandler {
        // This is WebKitErrorFrameLoadInterruptedByPolicyChange, which WKError lacks.
        private static let interruptedByPolicy = 102

        var loadedGeneration = 0
        // A new click cancels the load first, so a page leaving mid-load is a redirect.
        var provisional = false
        var selectionEnabled = false
        var observations: [NSKeyValueObservation] = []
        var onAddress: (URL) -> Void = { _ in }
        var onPhase: (LocalServerPreview.Phase) -> Void = { _ in }
        var onLoaded: (Bool) -> Void = { _ in }
        var onHistory: (Bool, Bool) -> Void = { _, _ in }
        var onNewPage: (URL) -> Void = { _ in }
        var onPick: (DesignElementSelection, URL, NSImage?) -> Void = { _, _, _ in }
        var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var saveDownload: @MainActor (String) -> URL? = { name in
            FilePicker.saveFile(suggestedName: name, prompt: "Save",
                                message: "Choose where to save the file from the running app.")
        }
        // A page that keeps sending files must not trap the person behind save panels.
        var declinedAt: ContinuousClock.Instant?
        private var personsLoad = false
        private var asking = false

        private func holdsBackFiles(_ webView: WKWebView) -> Bool {
            let resting = declinedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
            return resting || webView.window == nil
        }

        func setSelection(_ enabled: Bool, in webView: WKWebView) {
            guard selectionEnabled != enabled else { return }
            selectionEnabled = enabled
            applySelection(in: webView)
        }

        private func applySelection(in webView: WKWebView) {
            webView.evaluateJavaScript("window.__codeStationSetSelection?.(\(selectionEnabled));",
                                       in: nil, in: .defaultClient)
        }

        // A pick during a load would carry the next page's address.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == DesignWebContent.Coordinator.messageName,
                  message.frameInfo.isMainFrame, let webView = message.webView,
                  let body = message.body as? [String: Any] else { return }
            if body["kind"] as? String == "ready" {
                applySelection(in: webView)
                return
            }
            guard selectionEnabled, !provisional,
                  let selection = DesignElementSelection(message: body),
                  let page = webView.url else { return }
            let configuration = WKSnapshotConfiguration()
            let crop = selection.rect.insetBy(dx: -8, dy: -8).intersection(webView.bounds)
            if !crop.isNull, crop.width > 1, crop.height > 1 { configuration.rect = crop }
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                self?.onPick(selection, page, image)
            }
        }

        // A page sent off the machine is stopped, since its session would not follow it.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            let mainFrame = action.targetFrame?.isMainFrame == true
            // WebKit drops a link's `download` attribute unless this returns .download.
            if action.shouldPerformDownload,
               TranscriptLink.isLocalServer(url) || ["blob", "data"].contains(scheme) {
                decisionHandler(holdsBackFiles(webView) && action.buttonNumber == 0
                                ? .cancel : .download)
                return
            }
            // WebKit blocks a new-window link the page clicks by itself, but not a
            // Command-click the page makes, so that counts only with a mouse button.
            if TranscriptLink.isLocalServer(url), action.navigationType == .linkActivated,
               action.targetFrame == nil || (mainFrame && action.modifierFlags.contains(.command)) {
                if action.targetFrame == nil || action.buttonNumber > 0 { onNewPage(url) }
                decisionHandler(.cancel)
                return
            }
            if action.targetFrame != nil, !mainFrame {
                decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme)
                                ? .allow : .cancel)
                return
            }
            if mainFrame, TranscriptLink.isLocalServer(url) || url.absoluteString == "about:blank" {
                personsLoad = action.buttonNumber > 0
                decisionHandler(.allow)
                return
            }
            // A page's own click has no mouse button, so it cannot open the browser.
            if action.navigationType == .linkActivated, action.buttonNumber > 0,
               ["http", "https", "mailto"].contains(scheme), !mainFrame || !provisional {
                openInBrowser(url)
            } else if mainFrame, ["http", "https"].contains(scheme) {
                onPhase(.left(url))
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationResponsePolicy) -> Void) {
            let disposition = (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition") ?? ""
            let file = disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType
            let local = response.isForMainFrame
                || response.response.url.map(TranscriptLink.isLocalServer) == true
            guard file, local else {
                decisionHandler(.allow)
                return
            }
            let persons = response.isForMainFrame && personsLoad
            decisionHandler(holdsBackFiles(webView) && !persons ? .cancel : .download)
        }

        // Dev servers often serve HTTPS with a self-signed certificate. The connection
        // never leaves the machine, so the certificate is accepted as it is.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor @Sendable
                        (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  TranscriptLink.localServerHosts.contains(space.host),
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            provisional = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            provisional = false
            onPhase(.showing)
            // After a failure the old page runs on, so the address is read on commit.
            if let url = webView.url, TranscriptLink.isLocalServer(url) { onAddress(url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            provisional = false
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onPhase(.stopped)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        // The save panel runs modally, so another download can arrive while it is open.
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            guard !asking else {
                completionHandler(nil)
                return
            }
            asking = true
            let destination = saveDownload(suggestedFilename)
            asking = false
            guard let destination else {
                declinedAt = .now
                completionHandler(nil)
                return
            }
            // The save panel has already asked before replacing a file, and a download
            // fails when its destination exists.
            try? FileManager.default.removeItem(at: destination)
            completionHandler(destination)
        }

        // WebKit's configuration is not used, since it would share this page's handlers.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if TranscriptLink.isLocalServer(url) {
                onNewPage(url)
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                openInBrowser(url)
            }
            return nil
        }

        // Alerts are left to WebKit, since Code Station's dialog may already be in use.
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
            let urls = parameters.allowsMultipleSelection
                ? FilePicker.chooseFiles(prompt: "Choose", message: "Choose files for the running app.")
                : FilePicker.chooseFile(prompt: "Choose", message: "Choose a file for the running app.")
                    .map { [$0] } ?? []
            completionHandler(urls.isEmpty ? nil : urls)
        }

        private func report(_ error: Error) {
            let error = error as NSError
            guard error.code != NSURLErrorCancelled,
                  error.domain != "WebKitErrorDomain" || error.code != Self.interruptedByPolicy
            else { return }
            onPhase(error.code == NSURLErrorCannotConnectToHost
                    ? .unreachable : .failed(error.localizedDescription))
        }
    }

    private static let pickerScript = #"""
    (() => {
    \#(DesignWebContent.pickerHelpers)

      // The cursor goes in a sheet, not on the root element, which a server-rendered
      // app compares while it hydrates. The picker cannot reach into frames.
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(":root { cursor: crosshair !important } "
        + "iframe, frame, object, embed { pointer-events: none !important }");
      // An app can replace adopted sheets, so this one is put back on pointer moves.
      const keepSheet = () => {
        if (!document.adoptedStyleSheets.includes(sheet)) {
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
      };
      window.addEventListener("pointerover", () => { if (enabled) keepSheet(); }, true);
      window.__codeStationSetSelection = value => {
        enabled = Boolean(value);
        sheet.disabled = !enabled;
        if (enabled) keepSheet();
        else clearHighlight();
      };

      // Presses open menus and focus fields before the click that picks arrives.
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "dblclick",
                          "contextmenu", "auxclick"]) {
        window.addEventListener(type, event => {
          if (!enabled) return;
          event.preventDefault();
          event.stopImmediatePropagation();
        }, true);
      }
      window.addEventListener("click", event => {
        if (!enabled || event.isTrusted) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);

    \#(DesignWebContent.pickerEvents)

      // A page from the back-forward cache keeps its old state, so it asks again.
      const askForState = () =>
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({kind: "ready"});
      window.addEventListener("pageshow", event => { if (event.persisted) askForState(); });
      askForState();
    })();
    """#
}
