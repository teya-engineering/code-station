import SwiftUI

// What a reviewer of a design looks for and looks at. Pictures of every screen always go;
// the files and the design conversation are the person's to choose.
struct DesignOpinionChoices: View {
    @Binding var focus: Set<DesignSecondOpinion.Focus>
    @Binding var reading: DesignSecondOpinion.Reading

    var body: some View {
        SecondOpinionSection(title: "What to look for") {
            FlowRow(spacing: Space.sm) {
                ForEach(DesignSecondOpinion.Focus.allCases, id: \.self) { item in
                    ChoicePill(title: item.title, selected: focus.contains(item)) {
                        if !focus.insert(item).inserted { focus.remove(item) }
                    }
                    .accessibilityAddTraits(focus.contains(item) ? .isSelected : [])
                }
            }
        }
        SecondOpinionSection(title: "What they look at") {
            VStack(alignment: .leading, spacing: Space.sm) {
                row(title: "The HTML, handoff and theme", note: "To check contrast and tokens", on: $reading.source)
                row(title: "The design conversation", note: "Makes them think like the author",
                    warns: true, on: $reading.conversation)
            }
        }
    }

    private func row(title: String, note: String, warns: Bool = false, on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: Space.md) {
                Text(title).font(Typography.label)
                Spacer(minLength: 8)
                Text(note).font(Typography.caption)
                    .foregroundStyle(warns ? Theme.attentionText : Color.secondary)
            }
        }
        .toggleStyle(.appCheckbox)
    }
}

// The side panel beside the canvas: the seats while they look, then the notes they
// pinned, each with Keep and Dismiss. Hovering a note lights its pin, and a pin that is
// clicked brings its note into view. Hovering never scrolls the list, so moving the
// mouse across the cards or the canvas leaves the list where the user put it.
struct DesignOpinionPanel: View {
    let opinion: DesignOpinion
    let screens: [DesignScreen]
    let currentScreen: String?
    @Binding var hotNote: UUID?
    @Binding var revealedNote: UUID?
    let showScreen: (String) -> Void
    let keep: (UUID) -> Void
    let edit: (UUID, String) -> Void
    let dismissNote: (UUID) -> Void
    let send: () -> Void
    let retry: (SecondOpinion.Reviewer) -> Void
    let stop: (SecondOpinion.Reviewer) -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: UUID?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Space.lg)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.md) {
                        lanes
                        if let sent = opinion.sent, opinion.notes.isEmpty {
                            Label("Sent \(counted(sent, "note")) to the design agent", systemImage: "checkmark")
                                .font(Typography.label).foregroundStyle(Theme.dotOnText)
                        } else if !opinion.isRunning, opinion.notes.isEmpty,
                                  opinion.lanes.contains(where: { if case .finished = $0.state { true } else { false } }) {
                            Text("They found nothing worth raising.")
                                .font(Typography.detail).foregroundStyle(.secondary)
                        }
                        ForEach(Array(opinion.notes.enumerated()), id: \.element.id) { index, note in
                            card(note, number: index + 1).id(note.id)
                                .transition(.fold)
                        }
                    }
                    .padding(Space.lg)
                }
                .onChange(of: revealedNote) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Motion.reveal) { proxy.scrollTo(id, anchor: .center) }
                    revealedNote = nil
                }
            }
            if !opinion.notes.isEmpty { footer }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second opinion")
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: -6) {
                ForEach(Array(opinion.lanes.enumerated()), id: \.offset) {
                    ReviewAvatar(agent: $0.element.reviewer.agent, size: 22)
                }
            }
            Text("Second opinion").font(Typography.body.weight(.semibold))
            Spacer(minLength: 6)
            Text(status).font(Typography.detail).foregroundStyle(.secondary).lineLimit(1)
            GlyphButton(icon: "xmark", side: ControlHeight.xs, action: close)
                .appTooltip(opinion.isRunning ? "Stop and close" : "Close")
                .accessibilityLabel(opinion.isRunning ? "Stop the second opinion" : "Close the second opinion")
        }
    }

    private var status: String {
        if opinion.isRunning { return "Looking at \(counted(max(opinion.request.shots.count, screens.count), "screen"))" }
        let open = opinion.pending.count
        if opinion.notes.isEmpty { return "" }
        return open > 0 ? "\(open) to look at" : "All sorted"
    }

    @ViewBuilder private var lanes: some View {
        let shown = opinion.lanes.filter { lane in
            if case .finished = lane.state { return opinion.isRunning }
            return true
        }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(shown) { lane in
                    ReviewLane(reviewer: lane.reviewer, started: lane.started, ended: lane.ended,
                               activity: lane.activity, state: lane.state, fillsWidth: true,
                               stop: { stop(lane.reviewer) }, retry: { retry(lane.reviewer) },
                               dismiss: { stop(lane.reviewer) })
                }
            }
        }
    }

    private func card(_ note: DesignOpinion.PinnedNote, number: Int) -> some View {
        let hot = hotNote == note.id
        let kept = note.status == .kept
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("\(number)")
                    .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.onFill)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Self.tint(note.severity)))
                    .accessibilityHidden(true)
                HStack(spacing: -5) {
                    ForEach(Array(note.voices.enumerated()), id: \.offset) {
                        ReviewAvatar(agent: $0.element.reviewer.agent, size: 16)
                    }
                }
                Text(note.category).font(Typography.label)
                SeverityChip(severity: note.severity)
                Spacer(minLength: 0)
            }
            if note.voices.count > 1 {
                Label(note.voices.count == 2 ? "Both raised this" : "\(note.voices.count) raised this",
                      systemImage: "checkmark")
                    .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.dotOnText)
            }
            if editing == note.id {
                TextField("What the design agent should change", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.detail)
                    .lineLimit(2...8)
                    .padding(Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(Theme.border))
                HStack(spacing: Space.md) {
                    ActionButton(title: "Save and keep", tone: .green, height: ControlHeight.sm, size: Typography.Size.caption) {
                        animate(Motion.reveal) {
                            edit(note.id, draft)
                            editing = nil
                        }
                    }
                    .disabled(draft.isBlank)
                    InlineLink(title: "Cancel", size: Typography.Size.caption, tint: Color.secondary) {
                        animate(Motion.leave) { editing = nil }
                    }
                }
            } else {
                ReviewText(text: note.text, size: 12)
                ForEach(Array(note.voices.dropFirst().enumerated()), id: \.offset) { _, voice in
                    Text("\(voice.reviewer.label()): \(voice.text)")
                        .font(Typography.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.md) {
                    if kept {
                        Label(note.edited ? "Edited and kept" : "Kept", systemImage: "checkmark")
                            .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.dotOnText)
                    } else {
                        ActionButton(title: "Keep", tone: .green, height: ControlHeight.sm, size: Typography.Size.caption) {
                            animate(Motion.reveal) { keep(note.id) }
                        }
                        InlineLink(title: "Dismiss", size: Typography.Size.caption, tint: Color.secondary) {
                            animate(Motion.leave) { dismissNote(note.id) }
                        }
                    }
                    InlineLink(title: "Edit", size: Typography.Size.caption, tint: Color.secondary) {
                        draft = note.text
                        animate(Motion.reveal) { editing = note.id }
                    }
                    Spacer(minLength: 0)
                    place(note)
                }
            }
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(kept ? Theme.dotOn.opacity(0.06)
                                                            : note.severity == .must ? Theme.deletion.opacity(0.04) : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .strokeBorder(hot ? Self.tint(note.severity) : Theme.border, lineWidth: hot ? 2 : 1))
        .motion(Motion.hover, value: hot)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onPointerHover { inside in
            if inside { hotNote = note.id } else if hotNote == note.id { hotNote = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note \(number), \(note.category), \(note.severity.label). \(note.text)")
    }

    // Where the note is. One on another screen takes the canvas there.
    @ViewBuilder private func place(_ note: DesignOpinion.PinnedNote) -> some View {
        if let id = note.screen {
            let title = screens.first { $0.id == id }?.title ?? id
            if id == currentScreen || screens.count < 2 {
                Label("On \(title)", systemImage: "mappin")
                    .font(Typography.caption).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Button { showScreen(id) } label: {
                    // Lifted inside the label, since the button carries an AppKit tooltip
                    // that cannot be laid out under a scale.
                    Label("On \(title)", systemImage: "mappin")
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                        .contentShape(Rectangle())
                        .hoverLift()
                }
                .buttonStyle(.plain)
                .appTooltip("Show the \(title) screen")
            }
        } else {
            Label("The whole design", systemImage: "square.stack")
                .font(Typography.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var footer: some View {
        let count = opinion.kept.count
        return VStack(alignment: .leading, spacing: Space.sm) {
            ActionButton(title: count > 0 ? "Send \(counted(count, "note")) to the design agent" : "Keep a note to send it",
                         tone: .green, height: ControlHeight.md, size: Typography.Size.detail, fills: true, action: send)
                .disabled(count == 0)
            Text("Kept notes go to the design agent as your next prompt. Dismissed ones are gone for good.")
                .font(Typography.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // The note changes the user asked for are animated where they are made, so notes
    // that arrive from the reviewers while they work land without motion.
    private func animate(_ animation: Animation, _ change: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, change)
    }

    static func tint(_ severity: ReviewComment.Severity) -> Color {
        switch severity {
        case .must: Theme.deletion
        case .should: Theme.attention
        case .look: Color.secondary
        }
    }
}
