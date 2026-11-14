import SwiftUI

// One project the whole change spans, with how much of the change is in it.
struct WholeChangeAskScope: Identifiable {
    let name: String
    let files: Int
    let added: Int
    let removed: Int
    var id: String { name }
    var lines: Int { added + removed }
}

// Questions about the whole change, in a card that hangs under the header button that
// asks them. It hangs over the diff rather than sitting in the file list, so the answer
// shows where the click was and the code it points at stays in view beside it.
struct WholeChangeAskCard<Thread: View>: View {
    let navigation: ChangesNavigationMemory
    let open: [ReviewQuestion]
    let resolved: [ReviewQuestion]
    let scope: [WholeChangeAskScope]
    let agentTitle: String
    // A fork of the conversation has read the chat; any other agent answers from the diff.
    let forksConversation: Bool
    // The tallest the card may be, so it never runs off the bottom of the window.
    let maxHeight: CGFloat
    let ask: (String) -> Void
    // Esc stops an answer under way before it puts the card away.
    let escape: () -> Void
    let close: () -> Void
    // Draws one thread, open or folded to a line.
    @ViewBuilder let thread: (ReviewQuestion, Bool) -> Thread

    static var width: CGFloat { 452 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var frame: CGRect = .zero
    @State private var mapDrawn = false

    private var expanded: UUID? { WholeChangeThreads.expanded(navigation.askExpanded, in: open) }
    private var following: ReviewQuestion? {
        navigation.askFollowing.flatMap { id in (open + resolved).first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !scope.isEmpty { changeMap }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            threads
            composer
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
        .overlay(alignment: .topLeading) { notch }
        .elevation(.floating)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask about the whole change")
        .accessibilityAddTraits(.isModal)
        // The card is offered the whole height it may take but only draws what it holds,
        // from the top, so a short conversation leaves no empty card under it.
        .frame(height: maxHeight, alignment: .top)
        .onAppear {
            mapDrawn = true
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: navigation.askFollowing) { _, id in
            if id != nil { fieldFocused = true }
        }
    }

    // Points back at the button the card came from.
    @ViewBuilder private var notch: some View {
        if let origin = navigation.askOrigin, frame.width > 0 {
            let x = min(max(origin.x - frame.minX, 24), Self.width - 24)
            RoundedRectangle(cornerRadius: Radius.tag)
                .fill(Theme.card)
                .overlay(alignment: .topLeading) {
                    // Only the two outer edges carry the border, so the notch joins the card.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 14))
                        path.addLine(to: CGPoint(x: 0, y: 3))
                        path.addQuadCurve(to: CGPoint(x: 3, y: 0), control: .zero)
                        path.addLine(to: CGPoint(x: 14, y: 0))
                    }
                    .stroke(Theme.border, lineWidth: 1)
                }
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .offset(x: x - 7, y: -7)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.plan)
                .frame(width: 32, height: 32)
                .surface(Theme.plan.opacity(0.12), cornerRadius: Radius.card, border: Theme.plan.opacity(0.25))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Ask about the whole change")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text(forksConversation
                     ? "A side copy of \(agentTitle) answers. It has read the chat, can't edit files, and nothing it says goes back to the chat."
                     : "A read-only run of \(agentTitle) answers from the diff and the recent chat. It can't edit files, and nothing it says goes to the chat.")
                    .font(Typography.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlyphButton(icon: "xmark", side: ControlHeight.sm, action: close)
                .appTooltip("Put away  esc")
                .accessibilityLabel("Put away")
        }
        .padding(.leading, Space.xl).padding(.trailing, Space.lg).padding(.top, Space.xl).padding(.bottom, Space.lg)
    }

    // Where the change is: one bar split by how many lines each project changed, then a
    // row for each project with its files and lines.
    private var changeMap: some View {
        let total = max(scope.reduce(0) { $0 + $1.lines }, 1)
        return VStack(alignment: .leading, spacing: Space.md) {
            GeometryReader { proxy in
                let gaps = CGFloat(max(scope.count - 1, 0)) * 3
                HStack(spacing: Space.xxs) {
                    ForEach(scope) { project in
                        Capsule()
                            .fill(Theme.projectTint(for: project.name).colour)
                            .frame(width: mapDrawn || reduceMotion
                                   ? max((proxy.size.width - gaps) * CGFloat(project.lines) / CGFloat(total), 3) : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(Motion.draw, value: mapDrawn)
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mapSummary(total: total))
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.xs) {
                ForEach(scope) { project in
                    GridRow {
                        HStack(spacing: Space.sm) {
                            ProjectDot(tint: Theme.projectTint(for: project.name), size: 8)
                            Text(project.name).font(Typography.detail.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(counted(project.files, "file"))
                            .font(Typography.detail).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        HStack(spacing: Space.xs) {
                            Text("+\(project.added)").foregroundStyle(Theme.addition)
                            Text("\u{2212}\(project.removed)").foregroundStyle(Theme.deletion)
                                .opacity(project.removed == 0 ? 0.4 : 1)
                        }
                        .font(Typography.data).fixedSize()
                        .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(project.name), \(counted(project.files, "file")), "
                                        + "\(project.added) lines added, \(project.removed) removed")
                }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
    }

    private func mapSummary(total: Int) -> String {
        guard let largest = scope.max(by: { $0.lines < $1.lines }) else { return "" }
        guard scope.count > 1 else { return "\(largest.name) holds the whole change" }
        let percent = Int((Double(largest.lines) / Double(total) * 100).rounded())
        return "\(largest.name) holds \(percent) percent of the changed lines"
    }

    // The threads scroll inside the card once they outgrow it. The card is as tall as
    // what it holds, so a short conversation does not leave a tall empty card.
    private var threads: some View {
        ScrollViewReader { proxy in
            HuggingHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        if !resolved.isEmpty {
                            resolvedToggle.frame(maxWidth: .infinity)
                        }
                        if navigation.askShowsResolved {
                            ForEach(resolved) { question in
                                thread(question, true).id(question.id).transition(.fadeIn)
                            }
                        }
                        if open.isEmpty && !(navigation.askShowsResolved && !resolved.isEmpty) {
                            empty.transition(.fadeIn)
                        }
                        ForEach(open) { question in
                            thread(question, question.id == expanded).id(question.id).transition(.fadeIn)
                        }
                    }
                    .padding(.horizontal, Space.md).padding(.vertical, Space.md)
                    .motion(Motion.reveal, value: expanded)
                    .motion(Motion.reveal, value: open.map(\.id))
                    .motion(Motion.reveal, value: navigation.askShowsResolved)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Questions")
            .onAppear {
                if let expanded { proxy.scrollTo(expanded, anchor: .bottom) }
            }
            .onChange(of: open.last?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : Motion.reveal) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .layoutPriority(-1)
    }

    private var resolvedToggle: some View {
        let count = resolved.count == 1 ? "1 resolved question" : "\(resolved.count) resolved questions"
        return InlineLink(title: (navigation.askShowsResolved ? "Hide " : "Show ") + count,
                          size: Typography.Size.detail, tint: Color.secondary) {
            navigation.askShowsResolved.toggle()
        }
        .padding(.vertical, Space.xs)
    }

    private var empty: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.plan)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.plan.opacity(0.08)))
                .padding(.bottom, Space.xs)
                .accessibilityHidden(true)
            Text("Ask how this change fits together").font(Typography.title)
                .accessibilityAddTraits(.isHeader)
            Text("Good for the big picture: why it was built this way, what to read first, what it could break. To ask about a few lines, select them in the diff.")
                .font(Typography.detail).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
            VStack(spacing: Space.xs) {
                ForEach(WholeChangeThreads.starters(projects: scope.count), id: \.self) { starter in
                    WholeChangeStarter(text: starter) { ask(starter) }
                }
            }
            .padding(.top, Space.md)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Questions to start with")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.lg).padding(.top, Space.xl).padding(.bottom, Space.md)
    }

    // One box: the field, then where the answer stays and the button that asks.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let following {
                HStack(spacing: Space.sm) {
                    Image(systemName: "arrow.turn.down.right").font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.plan)
                    (Text("Following up on ").foregroundStyle(.secondary)
                     + Text(following.text).fontWeight(.semibold).foregroundStyle(Color.primary))
                        .font(Typography.detail).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GlyphButton(icon: "xmark", side: ControlHeight.xs) { navigation.askFollowing = nil }
                        .appTooltip("Ask a new question instead")
                        .accessibilityLabel("Ask a new question instead")
                }
                .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.plan.opacity(0.08)))
                .transition(.fadeIn)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                TextField(following == nil ? "Ask \(agentTitle) about the whole change" : "Ask a follow-up",
                          text: Binding(get: { navigation.askDraft }, set: { navigation.askDraft = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        navigation.askDraft += "\n"
                        return .handled
                    }
                    .onExitCommand(perform: escape)
                    .accessibilityLabel(following == nil ? "Question about the whole change" : "Follow-up question")
                    .accessibilityHint("Return asks. Shift-Return adds a line.")
                HStack(spacing: Space.md) {
                    Label("Stays in this review", systemImage: "lock")
                        .font(Typography.caption).foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                    Spacer(minLength: 8)
                    WholeChangeAskButton(title: following == nil ? "Ask" : "Ask follow-up",
                                         ready: !navigation.askDraft.isBlank, action: send)
                }
            }
            .padding(.leading, Space.lg).padding(.trailing, Space.sm).padding(.top, Space.md).padding(.bottom, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(fieldFocused ? Theme.plan.opacity(0.5) : Theme.border))
            .motion(Motion.hover, value: fieldFocused)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
            .onTapGesture { fieldFocused = true }
        }
        .padding(.horizontal, Space.lg).padding(.top, Space.md).padding(.bottom, Space.lg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .motion(Motion.reveal, value: navigation.askFollowing)
    }

    private func send() {
        guard !navigation.askDraft.isBlank else { return }
        ask(navigation.askDraft.trimmed)
        fieldFocused = true
    }

    private func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

// A question to start with. It is a whole question, so a click asks it at once.
private struct WholeChangeStarter: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: "questionmark.bubble")
                    .font(Typography.label)
                    .foregroundStyle(Theme.plan)
                Text(text).font(Typography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "return")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.plan)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Space.lg).frame(height: 32)
            .surface(hovering ? Theme.plan.opacity(0.06) : Theme.card, cornerRadius: Radius.control,
                     border: hovering ? Theme.plan.opacity(0.35) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
        .accessibilityLabel(text)
        .accessibilityHint("Asks it now")
    }
}

// The card's Ask button. With nothing typed it waits in the field's own grey rather than
// fading out, so it reads as not yet rather than broken.
private struct WholeChangeAskButton: View {
    let title: String
    let ready: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Text(title).font(Typography.label).fixedSize()
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                    .overlay(RoundedRectangle(cornerRadius: Radius.tag)
                        .stroke(ready ? Theme.card.opacity(0.5) : Theme.border))
            }
            .foregroundStyle(ready ? Theme.card : Color.secondary)
            .padding(.horizontal, Space.md).frame(height: 28)
            .surface(ready ? (hovering ? Theme.plan.opacity(0.86) : Theme.plan) : Theme.sunken,
                     cornerRadius: Radius.control, border: ready ? .clear : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .hoverLift(hovering && ready)
        .motion(Motion.control, value: ready)
        .onPointerHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(ready ? "" : "Type a question first")
    }
}

// A thread folded to one line: the question, where it stands and when it was asked.
struct WholeChangeFoldedThread<Badge: View>: View {
    let question: ReviewQuestion
    let open: () -> Void
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.md) {
                Text(question.text)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                badge()
                Text(question.created.formatted(date: .omitted, time: .shortened))
                    .font(Typography.data).foregroundStyle(.tertiary).fixedSize()
                Image(systemName: "chevron.down")
                    .font(Typography.micro).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.floating)
        .accessibilityLabel(question.spokenName)
        .accessibilityHint("Opens the thread")
    }
}
