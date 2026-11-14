import SwiftUI

struct DispatchResponsePane: View {
    let result: HTTPResult?
    let running: Bool
    let environment: ApiEnvironment
    let cancel: () -> Void
    let retry: () -> Void

    @Environment(DispatchStore.self) private var store
    @Namespace private var tabPanels
    @State private var document = DispatchResponseDocument(body: "")
    @State private var collapsed = false
    @State private var highlighted = AttributedString("")
    private typealias Tab = DispatchWorkbenchState.ResponseTab

    private var tabs: [Tab] {
        guard let result, result.failure == nil else { return [.body] }
        return [.body] + (document.table == nil ? [] : [.table]) + (result.headers.isEmpty ? [] : [.headers])
    }

    private var shown: Tab { tabs.contains(store.workbench.responseTab) ? store.workbench.responseTab : .body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            if let result, !running {
                toolbar
                if result.isTruncated {
                    note("Response truncated at the download limit. Only the received portion is shown and copied.")
                } else if document.structuredLimitReached {
                    note("Large response shown as text. Structured views are available up to 1 MB.")
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(environment.label) response: \(tabLabel(shown))")
                .accessibilityLabeledPair(role: .content, id: shown, in: tabPanels)
        }
        .background(Theme.card)
        .onChange(of: result, initial: true) { _, result in
            document = DispatchResponseDocument(body: result?.body ?? "", truncated: result?.isTruncated ?? false)
            collapsed = false
            highlight()
        }
        .onChange(of: collapsed) { _, _ in highlight() }
        .motion(Motion.reveal, value: running)
        .motion(Motion.reveal, value: shown)
        .motion(Motion.reveal, value: environment)
    }

    private var status: some View {
        HStack(spacing: Space.md) {
            Text("Response").font(Typography.label)
            if running {
                Text("Waiting for \(environment.label)…").font(Typography.caption).foregroundStyle(.secondary)
            } else if let result {
                Text(result.statusText)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(result.tint)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                    .background(result.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inset))
                    .transition(.fadeIn)
                ViewThatFits(in: .horizontal) {
                    Text("\(Int(result.duration * 1000)) ms · \(byteText(result.byteCount)) · \(environment.label)")
                    Text("\(Int(result.duration * 1000)) ms · \(environment.label)")
                }
                .font(Typography.caption).foregroundStyle(.secondary)
            } else {
                Text("Not sent in \(environment.label)").font(Typography.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            GlyphButton(icon: store.workbench.responseExpanded ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right", side: ControlHeight.sm) {
                store.workbench.responseExpanded.toggle()
            }
            .accessibilityLabel(store.workbench.responseExpanded ? "Restore request editor" : "Expand response")
            .appTooltip(store.workbench.responseExpanded ? "Restore request editor" : "Expand response")
        }
        .padding(.horizontal, Space.xxl).frame(height: 43)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var toolbar: some View {
        HStack(spacing: Space.lg) {
            DispatchTabs(items: tabs,
                         selection: Binding(get: { shown }, set: { store.workbench.responseTab = $0 }),
                         namespace: tabPanels, label: tabLabel,
                         detail: { $0 == .headers ? "\(result?.headers.count ?? 0)" : nil })
                .accessibilityLabel("Response view tabs")
            Spacer(minLength: 0)
            if shown == .body, document.collapsedBody != nil {
                InlineLink(title: collapsed ? "Expand array" : "Collapse array", size: Typography.Size.caption) { collapsed.toggle() }
            }
            if let text = copyable, !text.isEmpty {
                CopyButton("Copy", onCopy: { AccessibilityNotification.Announcement("Response copied").post() }) { text }
                    .accessibilityLabel(shown == .headers ? "Copy response headers" : "Copy response")
            }
        }
        .padding(.horizontal, Space.xxl)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if running {
            VStack(spacing: Space.md) {
                LoopSpinner(colour: Theme.accent, size: 22)
                Text("Sending to \(environment.label)").font(Typography.title)
                Text("Waiting for the response.").font(Typography.detail).foregroundStyle(.secondary)
                ActionButton(title: "Cancel request", tone: .outlined, action: cancel)
            }
        } else if let result {
            if let failure = result.failure {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text(failure).font(Typography.detail).foregroundStyle(Theme.deletion).textSelection(.enabled)
                    ActionButton(title: "Retry request", tone: .outlined, icon: "arrow.clockwise", action: retry)
                }.padding(Space.xxl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    if result.status >= 400 {
                        HStack {
                            Text("The server returned \(result.status). The response is shown below.")
                                .font(Typography.caption).foregroundStyle(Theme.deletion)
                            Spacer()
                            InlineLink(title: "Retry", size: Typography.Size.caption, action: retry)
                        }.padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
                    }
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
        } else {
            VStack(spacing: Space.md) {
                Image(systemName: "paperplane").font(.system(size: 25)).foregroundStyle(.secondary)
                Text("Your response will appear here").font(Typography.title)
                Text("Send this request to \(environment.label) to see the status, timing and body.")
                    .font(Typography.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(Space.xxl)
        }
    }

    private func bodyView(_ result: HTTPResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(result.body.isEmpty ? AttributedString("No body came back.") : highlighted)
                .font(Typography.data).lineSpacing(4)
                .foregroundStyle(ResponseStyle.base)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Space.xxl)
        }
        .background(ResponseStyle.background)
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
            }.textSelection(.enabled).padding(Space.xxl)
        }.background(ResponseStyle.background)
    }

    private func tableView(_ table: DispatchResponseDocument.Table) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if table.limited { note("Table preview limited to 500 rows, 30 columns and 500 characters per cell. JSON and Copy retain the full received body.") }
            if table.rows.isEmpty || table.columns.isEmpty {
                Text(table.rows.isEmpty ? "Empty array · 0 rows" : "This object has no fields.").font(Typography.detail).foregroundStyle(.secondary).padding(Space.xxl)
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
                    .padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
            .background(Theme.attention.opacity(0.08))
    }

    private func tabLabel(_ tab: Tab) -> String { tab == .body && document.isJSON ? "JSON" : tab.rawValue }

    private var copyable: String? {
        guard let result else { return nil }
        if let failure = result.failure { return failure }
        return shown == .headers ? result.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n") : result.body
    }

    private func highlight() {
        let body = collapsed ? document.collapsedBody ?? "" : result?.body ?? ""
        highlighted = document.structuredLimitReached ? AttributedString(body) : ResponseStyle.highlight(body)
    }

    private func byteText(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f kB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / Double(1024 * 1024))
    }
}
