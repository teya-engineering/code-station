import SwiftUI

// The answer to a request. It is one line until the first send, so the request has the
// room, and rises when a send starts. Once there is an answer the same line carries the
// status, the time, the size and the ways of looking at the body.
struct DispatchResponsePane: View {
    let result: HTTPResult?
    let running: Bool
    let environment: ApiEnvironment
    let startedAt: Date?
    // Counts the answers that landed while this request was on show. A new count plays
    // the landing; nil means the answer was already there.
    let landing: Int?
    // Off while the mark from the Send button is still on its way to become the spinner.
    let spinnerShown: Bool
    let needsSignIn: Bool
    let retry: () -> Void
    let signIn: () -> Void

    @Environment(DispatchStore.self) private var store
    @Namespace private var viewTrack
    @State private var document = DispatchResponseDocument(body: "")
    @State private var collapsed = false
    @State private var highlighted = AttributedString("")
    private typealias Tab = DispatchWorkbenchState.ResponseTab
    private static let foldLink = URL(string: "dispatch://fold")!
    private static let skeleton: [CGFloat] = [0.38, 0.62, 0.54, 0.7, 0.46, 0.58, 0.3]

    private var tabs: [Tab] {
        guard let result, result.failure == nil else { return [.body] }
        return [.body] + (document.table == nil ? [] : [.table]) + (result.headers.isEmpty ? [] : [.headers])
    }

    private var shown: Tab { tabs.contains(store.workbench.responseTab) ? store.workbench.responseTab : .body }
    private var expanded: Bool { store.workbench.responseExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: DispatchMetrics.responseHeaderHeight)
            if running || result != nil {
                if let result, !running {
                    strip(for: result)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(environment.label) response: \(tabLabel(shown))")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .onChange(of: result, initial: true) { _, result in
            document = DispatchResponseDocument(body: result?.body ?? "", truncated: result?.isTruncated ?? false)
            collapsed = false
            highlight()
        }
        .onChange(of: collapsed) { _, _ in highlight() }
        .motion(Motion.reveal, value: running)
        .motion(Motion.reveal, value: shown)
        .motion(Motion.reveal, value: environment)
        .motion(Motion.pop, value: landing)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            if running {
                LoopSpinner(colour: environment.brightAccent, size: DispatchMetrics.spinner)
                    .opacity(spinnerShown ? 1 : 0)
                Text("Waiting for \(environment.label)").font(Typography.label)
                ElapsedReading(since: startedAt)
                Spacer(minLength: 0)
                Text("esc cancels").font(Typography.caption).foregroundStyle(.secondary)
            } else if let result {
                answered(result)
            } else {
                Text("Response").font(Typography.label)
                Text("Not sent to \(environment.label) yet. Press ⌘↵ to send.")
                    .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, Space.pane).padding(.trailing, Space.lg)
    }

    @ViewBuilder private func answered(_ result: HTTPResult) -> some View {
        let tint = result.wasCancelled ? Theme.secondaryText : result.tint
        Text(statusLabel(result))
            .font(Typography.label)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.sm)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: Radius.inset))
            .fixedSize()
            .landingRings(result.wasCancelled ? nil : landing, colour: tint, cornerRadius: Radius.inset, reach: 1.6)
            .id(landing)
            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .identity))
            .accessibilityLabel("Status: \(statusLabel(result))")
        if !result.wasCancelled {
            LandedReading(milliseconds: Int(result.duration * 1000), plays: landing != nil)
                .id(landing)
        }
        if result.failure == nil {
            StatusRule()
            Text(byteText(result.byteCount)).font(Typography.code).foregroundStyle(.secondary).fixedSize()
        }
        Spacer(minLength: Space.md)
        if result.failure == nil {
            if tabs.count > 1 {
                HStack(spacing: Space.xxs) {
                    ForEach(tabs) { tab in
                        ChoicePill(title: tabLabel(tab), selected: shown == tab, thumb: viewTrack,
                                   count: tab == .headers ? result.headers.count : nil) {
                            store.workbench.responseTab = tab
                        }
                        .accessibilityLabel("Show the answer as \(tabLabel(tab))")
                    }
                }
                .padding(Space.xxs)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
                .motion(Motion.control, value: shown)
            }
            if let text = copyable, !text.isEmpty {
                CopyButton("Copy", onCopy: { AccessibilityNotification.Announcement("Response copied").post() }) { text }
                    .accessibilityLabel(shown == .headers ? "Copy response headers" : "Copy response")
            }
        }
        GlyphButton(icon: expanded ? "arrow.down.right.and.arrow.up.left"
                                   : "arrow.up.left.and.arrow.down.right", side: ControlHeight.sm) {
            store.workbench.responseExpanded.toggle()
        }
        .accessibilityLabel(expanded ? "Bring the request back" : "Give the answer the whole pane")
        .appTooltip(expanded ? "Bring the request back" : "Give the answer the whole pane")
    }

    private func statusLabel(_ result: HTTPResult) -> String {
        if result.wasCancelled { return "Cancelled" }
        return result.failure == nil ? result.statusText : "No answer"
    }

    // MARK: - Notes above the body

    @ViewBuilder private func strip(for result: HTTPResult) -> some View {
        if result.failure == nil, result.status >= 400 {
            if result.status == 401 {
                WarningStrip("\(environment.label) did not accept the token. Sign in, then send again.") {
                    if needsSignIn {
                        InlineLink(title: "Sign in to \(environment.label)", tint: Theme.warningText, action: signIn)
                    } else {
                        InlineLink(title: "Send again", tint: Theme.warningText, action: retry)
                    }
                }
            } else {
                WarningStrip("The server answered \(result.status). What it said is below.") {
                    InlineLink(title: "Send again", tint: Theme.warningText, action: retry)
                }
            }
        }
        if result.isTruncated {
            note("Response truncated at the download limit. Only the received portion is shown and copied.")
        } else if document.structuredLimitReached {
            note("Large response shown as text. Structured views are available up to 1 MB.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.pane).padding(.vertical, Space.sm)
            .background(Theme.attention.opacity(0.08))
    }

    // MARK: - Body

    @ViewBuilder private var content: some View {
        if running {
            // What came back last time stays on screen, dimmed, until the new answer
            // takes its place. A first send has nothing to keep, so it shows bars.
            if let result, result.failure == nil {
                bodyView(result).opacity(0.35).allowsHitTesting(false).accessibilityHidden(true)
            } else {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(Self.skeleton, id: \.self) { share in
                            Capsule().fill(ResponseStyle.base.opacity(0.09))
                                .frame(width: geometry.size.width * share, height: Space.md)
                        }
                    }
                    .padding(Space.pane)
                }
                .background(ResponseStyle.background)
                .accessibilityHidden(true)
            }
        } else if let result {
            if result.wasCancelled {
                PaneMessage(icon: "xmark.circle", title: "Send cancelled",
                            detail: "Nothing came back from \(environment.label).") {
                    ActionButton(title: "Send again", tone: .outlined, icon: "arrow.clockwise", action: retry)
                }
            } else if let failure = result.failure {
                PaneMessage(icon: "exclamationmark.triangle", title: "No answer from \(environment.label)",
                            detail: failure) {
                    // A request that was stopped before it left took no time, and the
                    // network is not what was wrong with it.
                    if result.duration > 0 {
                        Text("Check the address under Goes to, and that you are on the right network.")
                            .font(Typography.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    ActionButton(title: "Send again", tone: .outlined, icon: "arrow.clockwise", action: retry)
                }
            } else {
                ZStack {
                    bodyView(result)
                        .standbyPane(shown: shown == .body)
                        .allowsHitTesting(shown == .body).accessibilityHidden(shown != .body)
                    headersView(result)
                        .standbyPane(shown: shown == .headers)
                        .allowsHitTesting(shown == .headers).accessibilityHidden(shown != .headers)
                    if let table = document.table {
                        tableView(table)
                            .standbyPane(shown: shown == .table)
                            .allowsHitTesting(shown == .table).accessibilityHidden(shown != .table)
                    }
                }
            }
        }
    }

    private func bodyView(_ result: HTTPResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Group {
                if result.body.isEmpty {
                    Text("No body came back.").foregroundStyle(ResponseStyle.dim)
                } else {
                    Text(highlighted).foregroundStyle(ResponseStyle.base).tint(ResponseStyle.dim)
                }
            }
            .font(Typography.data).lineSpacing(Space.xs)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.pane)
        }
        .background(ResponseStyle.background)
        // The fold sits in the body, beside the array it folds, as a link in the text.
        .environment(\.openURL, OpenURLAction { url in
            guard url == Self.foldLink else { return .systemAction }
            collapsed.toggle()
            return .handled
        })
    }

    private func headersView(_ result: HTTPResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(result.headers) { header in
                    HStack(alignment: .top, spacing: Space.lg) {
                        Text(header.key).font(Typography.data.weight(.semibold)).foregroundStyle(ResponseStyle.key)
                            .frame(minWidth: 100, idealWidth: 180, maxWidth: 220, alignment: .leading)
                        Text(header.value).font(Typography.data).foregroundStyle(ResponseStyle.base)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.textSelection(.enabled).padding(Space.pane)
        }.background(ResponseStyle.background)
    }

    private func tableView(_ table: DispatchResponseDocument.Table) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if table.limited { note("Table preview limited to 500 rows, 30 columns and 500 characters per cell. JSON and Copy retain the full received body.") }
            if table.rows.isEmpty || table.columns.isEmpty {
                Text(table.rows.isEmpty ? "Empty array · 0 rows" : "This object has no fields.").font(Typography.detail).foregroundStyle(.secondary).padding(Space.pane)
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(table.rows.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(table.columns.indices, id: \.self) { column in
                                        Text(table.rows[index][column]).font(Typography.data).textSelection(.enabled)
                                            .frame(width: 170, alignment: .leading).padding(Space.md)
                                            .accessibilityLabel("\(table.columns[column]): \(table.rows[index][column])")
                                    }
                                }.overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(table.columns, id: \.self) { column in
                                    Text(column).font(Typography.caption.weight(.semibold))
                                        .frame(width: 170, alignment: .leading).padding(Space.md)
                                }
                            }.background(Theme.sidebar)
                        }
                    }
                }
                Text(counted(table.totalRows, "row")).font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.pane).padding(.vertical, Space.sm)
            }
        }
    }

    private func tabLabel(_ tab: Tab) -> String { tab == .body && document.isJSON ? "JSON" : tab.rawValue }

    private var copyable: String? {
        guard let result else { return nil }
        if let failure = result.failure { return failure }
        return shown == .headers ? result.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n") : result.body
    }

    private func highlight() {
        let body = result?.body ?? ""
        guard let fold = document.fold, !document.structuredLimitReached else {
            highlighted = document.structuredLimitReached ? AttributedString(body) : ResponseStyle.highlight(body)
            return
        }
        let items = counted(fold.count, "item")
        var link = AttributedString(collapsed ? "\(items), show all" : "fold \(items)")
        link.link = Self.foldLink
        link.foregroundColor = ResponseStyle.dim
        link.underlineStyle = .single
        let space = AttributedString(" ")
        highlighted = ResponseStyle.highlight(fold.head, isJSON: true) + space + link
            + (collapsed ? space : AttributedString(""))
            + ResponseStyle.highlight(collapsed ? fold.tail : fold.inner + fold.tail, isJSON: true)
    }

    private func byteText(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f kB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / Double(1024 * 1024))
    }
}

// How long the send has been out. It is a view of its own, with a width of its own, so
// its ticking redraws these few digits and nothing around them.
private struct ElapsedReading: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: since ?? .now, by: 0.1)) { context in
            Text(String(format: "%.1f s", max(0, context.date.timeIntervalSince(since ?? context.date))))
                .font(Typography.code)
                .monospacedDigit()
        }
        .frame(width: DispatchMetrics.elapsedWidth, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// How long the answer took. When it has just landed the figure counts up to its value.
private struct LandedReading: View {
    let milliseconds: Int
    let plays: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double

    init(milliseconds: Int, plays: Bool) {
        self.milliseconds = milliseconds
        self.plays = plays
        _progress = State(initialValue: plays ? 0 : 1)
    }

    var body: some View {
        CountingText(number: Double(milliseconds) * progress, unit: "ms")
            .fixedSize()
            .accessibilityLabel("\(milliseconds) milliseconds")
            .onAppear {
                guard progress < 1 else { return }
                if reduceMotion { progress = 1 } else { withAnimation(Motion.draw) { progress = 1 } }
            }
    }
}

nonisolated private struct CountingText: View, Animatable {
    var number: Double
    let unit: String

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        Text("\(Int(number.rounded())) \(unit)")
            .font(Typography.code)
            .monospacedDigit()
    }
}
