import SwiftUI

// One request being edited: its name, the address card with the Send button, the parts
// of the request under tabs, and the answer below.
struct RequestDetail: View {
    @State private var draft: SavedRequest
    @State private var copiedCurl = false
    @State private var copyReset: Task<Void, Never>?
    @State private var renamingTitle = false
    @State private var urlFocused = false
    // The path row under the pointer, whose :name lights up in the address.
    @State private var litPath: String?
    // A row that was just added, so its name takes the cursor.
    @State private var freshRow: UUID?
    @State private var dragHeight: CGFloat?

    @State private var flight: Flight?
    @State private var sendFrame = CGRect.zero
    @State private var splitFrame = CGRect.zero
    // Counts the answers that landed while this request was on screen. Each one plays the
    // landing once; an answer that was already there when the request was opened does not.
    @State private var landings: Int?
    // Which parts of "Goes to" changed with the environment, by the count they changed at.
    @State private var rolls: [Int: Int] = [:]
    @State private var switches = 0

    let openEnvironments: () -> Void
    let close: () -> Void

    @Environment(DispatchStore.self) private var store
    @Environment(DispatchRunner.self) private var runner
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    @Namespace private var tabPanels

    private typealias Tab = DispatchWorkbenchState.RequestTab
    private var tab: Tab { store.workbench.requestTab }
    nonisolated private static let space = "dispatch-request"
    private static let propertyInk = Theme.accentNSColor
    private static let problemInk = Theme.deletionNSColor
    private static let pathInk = NSColor(Theme.attentionText)
    private static let pathWash = NSColor(Theme.attention)

    init(request: SavedRequest, openEnvironments: @escaping () -> Void, close: @escaping () -> Void) {
        _draft = State(initialValue: request)
        self.openEnvironments = openEnvironments
        self.close = close
    }

    private var environment: ApiEnvironment { auth.active }
    private var running: Bool { runner.isRunning(draft.id, in: environment) }
    private var result: HTTPResult? { runner.result(draft.id, in: environment) }
    private var responseOpen: Bool { running || result != nil }
    private var responseExpanded: Bool { responseOpen && store.workbench.responseExpanded }

    private func resolved(in env: ApiEnvironment) -> DispatchAddress.Resolved {
        DispatchAddress.resolve(draft, environment: env, properties: auth.properties(for: env))
    }

    var body: some View {
        let address = resolved(in: environment)
        VStack(alignment: .leading, spacing: 0) {
            title
            addressCard(address)
                .padding(.horizontal, Space.pane)
            split
                .padding(.top, Space.md)
        }
        .coordinateSpace(.named(Self.space))
        .overlay {
            if let flight {
                FlightView(flight: flight, onLanded: { self.flight = nil }) {
                    Image(systemName: "paperplane.fill")
                        .font(Typography.micro)
                        .foregroundStyle(Theme.onFill)
                        .frame(width: DispatchMetrics.spinner, height: DispatchMetrics.spinner)
                        .background(environment.accentFill, in: Circle())
                }
                .id(flight.id)
            }
        }
        .onChange(of: draft) { _, new in store.update(new) }
        .onChange(of: store.selected) { _, request in
            if let request, request.id == draft.id, request != draft { draft = request }
        }
        .onChange(of: running) { wasRunning, running in
            guard wasRunning, !running else { return }
            flight = nil
            guard let result else { return }
            landings = (landings ?? 0) + 1
            AccessibilityNotification.Announcement("\(environment.label): \(result.wasCancelled ? "Cancelled" : result.statusText)").post()
        }
        .onChange(of: environment) { old, new in
            flight = nil
            // The parts that read differently in the new environment roll in, so the eye
            // lands on what the switch changed.
            let before = resolved(in: old).parts
            let after = resolved(in: new).parts
            switches += 1
            for (index, part) in after.enumerated() where part.substituted
                && (index >= before.count || before[index].text != part.text) {
                rolls[index] = switches
            }
        }
        .onExitCommand {
            if dialogs.current != nil { dialogs.dismiss() }
            else if menus.isOpen { menus.dismiss() }
            else if running { cancel() }
        }
    }

    // MARK: - Title

    private var requestMenu: [MenuEntry] {
        [.item("Rename") { beginRename() },
         .item(draft.isPinned ? "Unpin" : "Pin to top of folder") { store.togglePin(draft.id) },
         .item("Duplicate") {
             if let copy = store.duplicate(draft.id) { auth.copyBasicPassword(from: draft.id, to: copy) }
         },
         .item("Copy as curl", icon: "terminal", subtitle: "Secrets masked", action: copyAsCurl),
         .separator,
         .item("Delete request", kind: .destructive) {
             dialogs.show(deleteDialog(for: draft, store: store, auth: auth))
         }]
    }

    private func beginRename() {
        renamingTitle = true
        nameFocused = true
    }

    private var title: some View {
        HStack(spacing: Space.md) {
            Group {
                if renamingTitle {
                    TextField("Request name", text: $draft.name)
                        .textFieldStyle(.plain).focused($nameFocused)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                        .surface(Theme.card, cornerRadius: Radius.inset, border: environment.accent)
                        .frame(maxWidth: FormMetrics.pairedFieldsWidth)
                        .onSubmit { nameFocused = false }
                        .onExitCommand { nameFocused = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { renamingTitle = false } }
                        .accessibilityLabel("Request name")
                } else {
                    Button(action: beginRename) {
                        Text(draft.name.isEmpty ? "Untitled" : draft.name)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverFill(cornerRadius: Radius.inset)
                    .appTooltip("Rename")
                    .accessibilityLabel("Request name: \(draft.name)")
                    .accessibilityHint("Renames the request")
                }
            }
            .font(Typography.title)
            // The name's own padding, taken back so its words start on the pane's edge.
            .padding(.leading, -Space.sm)
            if let folder = store.folders.first(where: { $0.id == draft.folderID }) {
                Text("in \(folder.name)").font(Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if copiedCurl {
                Label("Copied curl", systemImage: "checkmark")
                    .font(Typography.caption.weight(.semibold)).foregroundStyle(environment.accent)
                    .transition(.fadeIn)
            }
            GlyphButton(icon: "ellipsis")
                .appMenu { requestMenu }
                .accessibilityLabel("More request actions")
        }
        .padding(.leading, Space.pane).padding(.trailing, Space.xl)
        .frame(height: DispatchMetrics.titleRowHeight)
        .motion(Motion.reveal, value: copiedCurl)
    }

    // MARK: - Address

    // The template on top and what it becomes underneath, in one card, so the line being
    // written and the place it goes are read together.
    private func addressCard(_ address: DispatchAddress.Resolved) -> some View {
        let paint = addressPaint
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    Text(draft.method.rawValue).font(Typography.code.weight(.semibold))
                        .foregroundStyle(draft.method.tint)
                        .contentTransition(.interpolate)
                    MenuChevron(size: 9)
                }
                .padding(.leading, Space.xl).padding(.trailing, Space.lg)
                .frame(height: DispatchMetrics.addressLineHeight)
                .contentShape(Rectangle())
                .hoverLift()
                .appMenu {
                    HTTPMethod.allCases.map { method in
                        .item(method.rawValue, checked: method == draft.method) { draft.method = method }
                    }
                }
                .accessibilityLabel("Request method: \(draft.method.rawValue)")
                StatusRule()
                TintedLineField(text: $draft.url, placeholder: "https://host/path",
                                size: Typography.Size.body, marks: paint.marks, lit: paint.lit,
                                label: "Request address",
                                onFocusChange: { urlFocused = $0 },
                                onSubmit: send, onCancel: close)
                    .padding(.horizontal, Space.lg)
                sendButton(blocked: address.problem)
                    .padding(.trailing, Space.sm)
            }
            .frame(height: DispatchMetrics.addressLineHeight)
            goesTo(address)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(urlFocused ? environment.accent : Theme.border, lineWidth: urlFocused ? 1.5 : 1))
        .overlay(alignment: .top) {
            wire
                .padding(.horizontal, Space.lg)
                .offset(y: DispatchMetrics.addressLineHeight - DispatchMetrics.wireHeight / 2)
        }
        .motion(Motion.control, value: draft.method)
        .motion(Motion.control, value: environment)
        .motion(Motion.control, value: running)
        .motion(Motion.hover, value: urlFocused)
    }

    private var addressPaint: (marks: [TintedLineField.Mark], lit: NSRange?) {
        let properties = auth.properties(for: environment)
        var marks: [TintedLineField.Mark] = []
        var lit: NSRange?
        var location = 0
        for token in DispatchAddress.tokens(in: draft.url) {
            let range = NSRange(location: location, length: (token.text as NSString).length)
            switch token {
            case .text:
                break
            case .property(let name, _):
                let known = DispatchAddress.isKnown(name, properties: properties)
                let ink = known ? Self.propertyInk : Self.problemInk
                marks.append(.init(range: range, ink: ink, wash: ink, problem: !known))
            case .path(let name):
                marks.append(.init(range: range, ink: Self.pathInk, wash: Self.pathWash))
                if name == litPath { lit = range }
            }
            location += range.length
        }
        return (marks, lit)
    }

    // The button names the place, so where the request goes is read at the moment of
    // sending. When it cannot be sent it carries the reason as its hint.
    private func sendButton(blocked problem: String?) -> some View {
        let press = {
            guard dialogs.current == nil, !menus.isOpen else { return }
            if running { cancel() } else { send() }
        }
        return ActionButton(title: running ? "Cancel" : "Send to \(environment.label)",
                            tone: running ? .outlined : environment.buttonTone,
                            icon: running ? nil : "paperplane",
                            shortcut: running ? "esc" : "⌘↵",
                            keyboardShortcut: KeyboardShortcut(.return, modifiers: .command),
                            action: press)
            .disabled(!running && problem != nil)
            .background {
                Button("", action: press)
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .control)
                    .disabled(!running && problem != nil).opacity(0).accessibilityHidden(true)
            }
            // A disabled button takes no hover, so a clear layer over it shows the reason.
            .overlay {
                if !running, let problem {
                    Color.clear.contentShape(Rectangle()).appTooltip(problem).accessibilityHidden(true)
                }
            }
            .accessibilityHint(running ? "" : problem ?? "")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { sendFrame = $0 }
    }

    // The line between the template and where it goes. A comet runs along it while the
    // request is out, and it draws full in the answer's colour when one lands.
    private var wire: some View {
        ZStack {
            if running {
                CometLine(colour: environment.brightAccent)
                    .transition(.opacity)
            } else if let landings, let result, !result.wasCancelled, !reduceMotion {
                LandedLine(colour: result.tint)
                    .id(landings)
            }
        }
        .frame(height: DispatchMetrics.wireHeight)
        .allowsHitTesting(false)
    }

    private func goesTo(_ address: DispatchAddress.Resolved) -> some View {
        HStack(spacing: Space.md) {
            Text("Goes to").font(Typography.caption).foregroundStyle(.secondary).fixedSize()
            if let problem = address.problem {
                Text(problem)
                    .font(Typography.caption).foregroundStyle(Theme.deletion)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appTooltip(problem)
                    .transition(.fadeIn)
            } else {
                GoesToLine(parts: address.parts, tint: environment.brightAccent, rolls: rolls)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appTooltip(address.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Goes to \(address.text)")
            }
            DispatchTokenChip(environment: environment, mode: draft.authMode, openEnvironments: openEnvironments)
        }
        .padding(.leading, Space.xl).padding(.trailing, Space.md)
        .frame(height: DispatchMetrics.goesToHeight)
        .background(Theme.sunken)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .motion(Motion.reveal, value: address.problem)
    }

    // MARK: - Request parts and the answer

    private var split: some View {
        GeometryReader { geometry in
            let total = geometry.size.height
            let height = !responseOpen ? DispatchSplitLayout.closedHeight
                : DispatchSplitLayout.responseHeight(dragHeight ?? store.responseHeight, available: total)
            let showsGrip = responseOpen && !responseExpanded
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    tabs
                    ZStack {
                        ForEach(Tab.allCases) { item in
                            editor(for: item)
                                .standbyPane(shown: tab == item)
                                .allowsHitTesting(tab == item && !responseExpanded)
                                .accessibilityHidden(tab != item || responseExpanded)
                                .disabled(tab != item || responseExpanded)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(item.rawValue)
                                .accessibilityLabeledPair(role: .content, id: item, in: tabPanels)
                        }
                    }
                    .clipped()
                    .motion(Motion.reveal, value: tab)
                }
                .frame(height: responseExpanded ? 0
                       : max(0, total - height - (showsGrip ? DispatchSplitLayout.handleHeight : 0)))
                .clipped()
                .allowsHitTesting(!responseExpanded)
                .disabled(responseExpanded)
                .accessibilityHidden(responseExpanded)
                if showsGrip {
                    DispatchResponseGrip(height: height, availableHeight: total, dragHeight: $dragHeight)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                DispatchResponsePane(result: result, running: running, environment: environment,
                                     startedAt: runner.startedAt(draft.id, in: environment),
                                     landing: landings, spinnerShown: flight == nil,
                                     needsSignIn: draft.authMode == .environmentToken
                                         && !auth.isAuthenticated(for: environment),
                                     retry: send,
                                     signIn: { dispatchSignIn(environment, auth: auth, openSettings: openEnvironments) })
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
            .motion(Motion.control, value: responseExpanded)
            .motion(Motion.control, value: responseOpen)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { splitFrame = $0 }
    }

    private var tabs: some View {
        DispatchTabs(items: Tab.allCases, selection: Binding(get: { tab }, set: { store.workbench.requestTab = $0 }),
                     namespace: tabPanels, label: { $0.rawValue }, detail: detail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.pane)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            .accessibilityLabel("Request configuration tabs")
    }

    private func detail(for tab: Tab) -> String? {
        switch tab {
        case .parameters: countDetail(draft.queryParams.count + draft.pathNames.count)
        case .headers: countDetail(draft.headers.count)
        case .body: draft.bodyType == .none ? nil : draft.bodyType.label
        case .auth: draft.authMode == .none ? "off" : nil
        }
    }

    private func countDetail(_ count: Int) -> String? { count == 0 ? nil : "\(count)" }

    @ViewBuilder private func editor(for tab: Tab) -> some View {
        switch tab {
        case .parameters: parameterEditor
        case .headers: headerEditor
        case .body: bodyEditor
        case .auth: authEditor
        }
    }

    // One list: a row for each :name in the address, then the query rows. The path rows
    // follow the address, so they are not added, turned off or removed by hand.
    private var parameterEditor: some View {
        let names = draft.pathNames
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if !names.isEmpty || !draft.queryParams.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(names, id: \.self) { name in
                            DispatchPathRow(name: name,
                                            value: Binding(get: { draft.pathValue(for: name) },
                                                           set: { draft.setPathValue($0, for: name) }),
                                            first: name == names.first) { inside in
                                if inside { litPath = name } else if litPath == name { litPath = nil }
                            }
                        }
                        ForEach($draft.queryParams) { $param in
                            DispatchFieldRow(field: $param, kind: "QUERY", namePlaceholder: "name",
                                             first: names.isEmpty && param.id == draft.queryParams.first?.id,
                                             focusesName: param.id == freshRow) {
                                draft.queryParams.removeAll { $0.id == param.id }
                            }
                            .transition(.fadeIn)
                        }
                    }
                    .rowCard()
                }
                HStack(spacing: Space.xl) {
                    ActionButton(title: "Add query parameter", tone: .outlined, height: ControlHeight.md,
                                 icon: "plus") {
                        let row = HeaderField(key: "", value: "")
                        freshRow = row.id
                        draft.queryParams.append(row)
                    }
                    Text(names.isEmpty ? "Write :name in the address to add a path parameter."
                                       : "Path rows follow the :names in the address.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.pane).padding(.vertical, Space.xl)
        }
        .frame(maxHeight: .infinity)
        .motion(Motion.control, value: draft.queryParams.map(\.id))
        .motion(Motion.control, value: names)
    }

    private var headerEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if draft.headers.isEmpty {
                    Text("No headers of your own. The ones a request needs, such as Content-Type for a body, are still added.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach($draft.headers) { $header in
                            DispatchFieldRow(field: $header, isHeader: true,
                                             first: header.id == draft.headers.first?.id,
                                             focusesName: header.id == freshRow && header.key.isEmpty,
                                             focusesValue: header.id == freshRow && !header.key.isEmpty) {
                                draft.headers.removeAll { $0.id == header.id }
                            }
                            .transition(.fadeIn)
                        }
                    }
                    .rowCard()
                }
                ActionButton(title: "Add header", tone: .outlined, height: ControlHeight.md,
                             icon: "plus", disclosure: true)
                    .appMenu {
                        [.item("Content-Type", subtitle: "Arrives filled in as application/json") {
                             addHeader("Content-Type", BodyType.json.contentType ?? "")
                         },
                         .item("Accept", subtitle: "Asks the server to answer in JSON") {
                             addHeader("Accept", BodyType.json.contentType ?? "")
                         },
                         .item("Authorization", subtitle: "A token of your own. It wins over Auth.") {
                             addHeader("Authorization", "")
                         },
                         .separator,
                         .item("Custom header", subtitle: "Starts empty") { addHeader("", "") }]
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.pane).padding(.vertical, Space.xl)
        }
        .frame(maxHeight: .infinity)
        .motion(Motion.control, value: draft.headers.map(\.id))
    }

    private func addHeader(_ key: String, _ value: String) {
        let row = HeaderField(key: key, value: value)
        freshRow = row.id
        draft.headers.append(row)
    }

    // The type picker lives in the pane rather than on the tab row, which has no room
    // to spare once the tab labels carry their counts.
    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.xs) {
                ForEach(BodyType.allCases) { kind in
                    ChoicePill(title: kind.label, selected: draft.bodyType == kind) {
                        draft.bodyType = kind
                    }
                }
                Spacer(minLength: Space.lg)
                // Offered only when it would change something, so a body that does not
                // parse yet or is already tidy shows nothing to press.
                if draft.bodyType == .json,
                   let formatted = JSONFormat.pretty(draft.body), formatted != draft.body {
                    InlineLink(title: "Tidy up", tint: environment.accent) {
                        draft.body = formatted
                    }
                }
            }
            if draft.bodyType == .none {
                note("This request is sent without a body. Pick JSON, Text or Form to add one.")
            } else {
                if !draft.method.canCarryBody {
                    note("A \(draft.method.rawValue) request is sent without a body. "
                         + "This one is kept and goes out again if you switch to POST, PUT, PATCH or DELETE.")
                } else if draft.bodyType == .form {
                    note("One key=value per line. Each pair is URL-encoded and joined with &.")
                }
                if draft.bodyType == .json {
                    CodeEditorView(documentID: "\(draft.id)-body",
                                   text: $draft.body,
                                   language: .json,
                                   matches: [],
                                   currentMatch: nil)
                        .padding(.vertical, Space.xs)
                        .cardSurface(cornerRadius: Radius.card)
                } else {
                    TextEditor(text: $draft.body)
                        .font(Typography.code)
                        .scrollContentBackground(.hidden)
                        .padding(Space.md)
                        .cardSurface(cornerRadius: Radius.card)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Space.pane).padding(.vertical, Space.xl)
    }

    private var authEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    ForEach(AuthMode.allCases) { mode in
                        ChoicePill(title: mode.label, selected: draft.authMode == mode) { draft.authMode = mode }
                    }
                }

                switch draft.authMode {
                case .none:
                    note("Nothing is added. A request that needs an Authorization header can still carry one of its own from Headers.")
                case .environmentToken:
                    note("Adds the token of whichever environment you send to, as \(auth.config(for: environment).headerPrefix) <token>. An Authorization header of your own still wins.")
                    EnvironmentTokenControls(env: environment)
                case .basic:
                    LabeledField("USERNAME") {
                        TextField("username", text: $draft.basicUsername)
                            .appTextField(size: Typography.Size.caption)
                    }
                    LabeledField("PASSWORD") {
                        SecretField(placeholder: "Kept in the Keychain, never in the request file",
                                    text: basicPassword,
                                    accent: environment.accent)
                    }
                    note("Sent the same way in every environment. Base64 hides nothing on the way, so use it on https only. An Authorization header of your own still wins.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Space.pane).padding(.vertical, Space.xl)
        }
        .frame(maxHeight: .infinity)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The password is the one part of a request that is not in the request file, so it is
    // read and written straight through to the store that owns the Keychain.
    private var basicPassword: Binding<String> {
        let id = draft.id
        return Binding(get: { auth.basicPassword(for: id) },
                       set: { auth.setBasicPassword($0, for: id) })
    }

    // MARK: - Sending

    private func send() {
        guard !running, dialogs.current == nil, !menus.isOpen else { return }
        // The draft is what the user is looking at, and it may be a keystroke ahead of
        // the store, so the run is built from it rather than from the saved copy.
        let request = draft
        let env = environment
        let properties = auth.properties(for: env)
        guard DispatchAddress.resolve(request, environment: env, properties: properties).problem == nil else { return }
        guard env.isDangerous else {
            fire(request, in: env, properties: properties)
            return
        }
        // A live environment asks once per send. There is no way to stop it asking; the
        // prompt is the guard.
        let safe = auth.environments.first { !$0.isDangerous }
        var actions = [
            Dialog.Action(label: "Send to \(env.label)", kind: .destructive) {
                fire(request, in: env, properties: properties)
            }
        ]
        if let safe {
            actions.append(Dialog.Action(label: "Switch to \(safe.label)") {
                auth.active = safe
            })
        }
        actions.append(Dialog.Action(label: "Cancel", kind: .cancel))
        dialogs.show(Dialog(
            title: "Send to \(env.label)?",
            message: consequence(of: request.method, safe: safe),
            content: AnyView(ResolvedRequestBox(request: request, environment: env, properties: properties)),
            actions: actions,
            width: 440,
            isModal: true))
    }

    private func fire(_ request: SavedRequest, in env: ApiEnvironment, properties: [EnvironmentProperty]) {
        takeOff()
        runner.start(request, environment: env, properties: properties) {
            await authorization(for: request, in: env)
        }
    }

    // A mark leaves the Send button and lands where the answer will show, as the spinner.
    // The response may still be closed, so it flies to where the header is about to be.
    private func takeOff() {
        guard !reduceMotion, sendFrame != .zero, splitFrame != .zero else { return }
        let side = DispatchMetrics.spinner
        let height = store.workbench.responseExpanded ? splitFrame.height
            : DispatchSplitLayout.responseHeight(store.responseHeight, available: splitFrame.height)
        let from = CGRect(x: sendFrame.minX + Space.lg, y: sendFrame.midY - side / 2, width: side, height: side)
        let to = CGRect(x: splitFrame.minX + Space.pane,
                        y: splitFrame.maxY - height + (DispatchMetrics.responseHeaderHeight - side) / 2,
                        width: side, height: side)
        flight = Flight(from: from, to: to)
    }

    // Built per send rather than held, so an expired token is refreshed on the way out
    // instead of failing the call.
    private func authorization(for request: SavedRequest,
                               in env: ApiEnvironment) async -> String? {
        if request.headers.contains(where: { $0.enabled && $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) { return nil }
        switch request.authMode {
        case .none:
            return nil
        case .environmentToken:
            return await auth.authorizationHeader(for: env)
        case .basic:
            return auth.basicHeader(username: request.basicUsername, requestID: request.id)
        }
    }

    private func cancel() {
        runner.cancel(draft.id, in: environment)
    }

    private func copyAsCurl() {
        let request = draft
        let env = environment
        let properties = auth.properties(for: env)
        let resolved = DispatchRunner.resolve(request, environment: env, authorization: nil,
                                              properties: properties, masked: true)
        guard resolved.problems.isEmpty else {
            dialogs.show(.notice("Cannot copy this request", message: resolved.problems.joined(separator: "\n")))
            return
        }
        Pasteboard.copy(CurlCommand.text(for: request, environment: env,
                                         authorization: request.authMode == .none ? nil : "REDACTED",
                                         properties: properties))
        copiedCurl = true
        AccessibilityNotification.Announcement("Copied curl with secrets masked").post()
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedCurl = false
        }
    }

    private func consequence(of method: HTTPMethod, safe: ApiEnvironment?) -> String {
        let verb = switch method {
        case .delete: "deletes"
        case .post: "creates"
        case .put, .patch: "changes"
        case .get, .head: "runs against"
        }
        return "This \(verb) live data. Switch to \(safe?.label ?? "another environment") if you meant to test."
    }
}

// Signing in from wherever the missing token is noticed. An environment that is not set
// up yet, or one whose sign-in ends on a page to paste back, opens its settings.
@MainActor
func dispatchSignIn(_ env: ApiEnvironment, auth: DispatchAuthStore, openSettings: () -> Void) {
    let config = auth.config(for: env)
    guard config.missing.isEmpty else { return openSettings() }
    auth.authenticate(env)
    if config.grant.usesBrowser && !config.usesLoopback { openSettings() }
}

// Exactly what the confirmation is about: the method and the URL as it will be sent.
private struct ResolvedRequestBox: View {
    let request: SavedRequest
    let environment: ApiEnvironment
    var properties: [EnvironmentProperty] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(request.method.rawValue)
                .font(Typography.data.weight(.semibold))
                .foregroundStyle(Theme.deletion)
            Text(DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                        properties: properties, masked: true).url).font(Typography.data)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .cardSurface(cornerRadius: Radius.control)
    }
}

// The address as it will be sent. The parts that were filled in are tinted, and the ones
// an environment switch changed roll in with a wash. When the line is too long to show
// whole it falls back to one truncated line, which cannot roll part by part.
private struct GoesToLine: View {
    let parts: [DispatchAddress.Part]
    let tint: Color
    let rolls: [Int: Int]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    GoesToPart(part: part, tint: tint, roll: part.substituted ? rolls[index] : nil)
                }
            }
            .fixedSize()
            .motion(Motion.control, value: rolls)
            parts.reduce(Text("")) { line, part in
                line + Text(part.text)
                    .font(part.substituted ? Typography.data.weight(.semibold) : Typography.data)
                    .foregroundStyle(part.substituted ? tint : Color.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
        }
    }
}

private struct GoesToPart: View {
    let part: DispatchAddress.Part
    let tint: Color
    let roll: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(part.text)
            .font(part.substituted ? Typography.data.weight(.semibold) : Typography.data)
            .foregroundStyle(part.substituted ? tint : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .id(roll)
            .transition(reduceMotion ? .identity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(y: Space.sm)), removal: .identity))
            .background {
                if let roll, !reduceMotion {
                    WashMark(tint: tint).id(roll)
                }
            }
    }
}

// A wash of colour behind words that have just changed, fading as soon as it is drawn.
private struct WashMark: View {
    let tint: Color
    @State private var faded = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.tag)
            .fill(tint.opacity(faded ? 0 : 0.26))
            .onAppear { withAnimation(Motion.wash) { faded = true } }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// The line under the address drawing itself full in the answer's colour, then letting go.
private struct LandedLine: View {
    let colour: Color
    @State private var drawn = false
    @State private var gone = false

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(colour)
                .frame(width: drawn ? geometry.size.width : 0)
        }
        .opacity(gone ? 0 : 1)
        .onAppear {
            withAnimation(Motion.draw) {
                drawn = true
            } completion: {
                withAnimation(Motion.reveal) { gone = true }
            }
        }
    }
}
