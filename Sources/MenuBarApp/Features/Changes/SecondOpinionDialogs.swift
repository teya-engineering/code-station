import AppKit
import SwiftUI

// The second opinion is asked in a card hung off the control that opened it
// (`SecondOpinionAskCard`). While the reviewers read, the header control opens a small
// panel of their lanes; once they are done, it opens the findings dialog to go through
// what they found. The review bar only says what will be sent.

// What a second opinion is asked to read.
enum SecondOpinionScopeChoice: Hashable {
    case all, file, sinceReview
}

// Where the second opinion stands, which is what the header's control says and opens.
enum SecondOpinionStatus: Equatable {
    case ask
    case reviewing(agents: [AgentKind], started: Date, pending: Int)
    case failed(AgentKind)
    case ready(agents: [AgentKind], pending: Int)
    case settled(kept: Int, dismissed: Int)

    @MainActor
    init(reviews: ReviewCommentStore, sessionID: UUID) {
        self.init(runs: reviews.runs(sessionID),
                  findings: reviews.comments(sessionID).filter { $0.reviewer != nil },
                  dismissed: reviews.dismissedFindings(sessionID).count)
    }

    init(runs: [SecondOpinionRun], findings: [ReviewComment], dismissed: Int) {
        let pending = findings.filter(\.isPending)
        let running = runs.filter(\.isRunning)
        if !running.isEmpty {
            self = .reviewing(agents: unique(running.map(\.agent)), started: running.map(\.started).min() ?? Date(),
                              pending: pending.count)
        } else if let failed = runs.first(where: { if case .failed = $0.state { true } else { false } }),
                  pending.isEmpty {
            self = .failed(failed.agent)
        } else if !pending.isEmpty {
            let voices = Set(pending.flatMap(\.reviewers))
            self = .ready(agents: AgentKind.allCases.filter(voices.contains), pending: pending.count)
        } else if !runs.isEmpty {
            self = .settled(kept: findings.count { !$0.isPending }, dismissed: dismissed)
        } else {
            self = .ask
        }
    }
}

enum SecondOpinionFindings {
    // Findings by file, the file with the most serious one first, and inside a file the
    // most serious first, then by line.
    static func ordered(_ findings: [ReviewComment]) -> [ReviewComment] {
        func rank(_ comment: ReviewComment) -> Int {
            comment.severity.flatMap { ReviewComment.Severity.allCases.firstIndex(of: $0) }
                ?? ReviewComment.Severity.allCases.count
        }
        var files: [String] = []
        var byFile: [String: [ReviewComment]] = [:]
        for finding in findings {
            let key = ReviewRound.fileKey(root: finding.root, path: finding.path)
            if byFile[key] == nil { files.append(key) }
            byFile[key, default: []].append(finding)
        }
        let sortedFiles = files.enumerated().sorted { a, b in
            let left = byFile[a.element]!.map(rank).min()!
            let right = byFile[b.element]!.map(rank).min()!
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
        return sortedFiles.flatMap { key in
            byFile[key]!.sorted { rank($0) == rank($1) ? $0.line < $1.line : rank($0) < rank($1) }
        }
    }

    // The next finding still to decide after the given one, going round to the start.
    static func next(after id: UUID?, in list: [ReviewComment], undecided: (ReviewComment) -> Bool) -> UUID? {
        let start = list.firstIndex { $0.id == id } ?? -1
        let rotated = list[(start + 1)...] + list[..<max(0, start + 1)]
        return rotated.first(where: undecided)?.id
    }
}

// Each agent once, in the order given. Two seats can run the same agent on two models.
private func unique(_ agents: [AgentKind]) -> [AgentKind] {
    var seen = Set<AgentKind>()
    return agents.filter { seen.insert($0).inserted }
}

private func names(_ agents: [AgentKind]) -> String {
    let titles = agents.map(\.title)
    guard titles.count > 1 else { return titles.first ?? "" }
    return titles.dropLast().joined(separator: ", ") + " and " + titles.last!
}

@MainActor
private func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
}

func clock(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

// A small turning arc, the sign a reviewer is still at work. Drawn rather than an
// NSProgressIndicator so it can sit on an avatar at any size. Still for reduced motion.
private struct ReviewerSpinner: View {
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "clock").font(.system(size: size * 0.7, weight: .bold))
                    .foregroundStyle(Theme.accent)
            } else {
                LoopSpinner(colour: Theme.accent, size: size * 0.76)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Theme.card))
        .accessibilityHidden(true)
    }
}

private struct BadgedAvatar: View {
    let agent: AgentKind
    var size: CGFloat = 20
    var badge: Badge?

    enum Badge { case working, done }

    var body: some View {
        ReviewAvatar(agent: agent, size: size)
            .overlay(alignment: .bottomTrailing) {
                switch badge {
                case .working:
                    ReviewerSpinner(size: max(9, size * 0.45)).offset(x: size * 0.15, y: size * 0.15)
                case .done:
                    Image(systemName: "checkmark").font(.system(size: size * 0.24, weight: .heavy))
                        .foregroundStyle(Theme.onFill)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .background(Circle().fill(Theme.dotOn))
                        .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                        .offset(x: size * 0.15, y: size * 0.15)
                        .accessibilityHidden(true)
                case nil:
                    EmptyView()
                }
            }
    }
}

// MARK: - Shared frame

// The header, body and footer every second opinion dialog is drawn in. The message
// changes with what is asked and how far it has got, so it stays on screen under the
// band rather than behind a question mark.
private struct DialogFrame<Trailing: View, Content: View, Footer: View>: View {
    let title: String
    let icon: String
    let message: String
    // Escape closes the dialog unless something inside it, such as an edit, wants the key.
    var escapeCloses = true
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(name: title, icon: icon) {
                trailing()
            }
            .padding(.horizontal, Space.pane)
            .headerBand()
            Text(message).font(Typography.body).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .padding(.horizontal, Space.pane).padding(.top, Space.lg)
            content()
            HStack(spacing: Space.md) { footer() }
                .padding(.leading, Space.pane).padding(.trailing, Space.lg).padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.card)
        // No dialog draws a close button, so Escape is the way out that every one of
        // them shares, held by a button nobody sees.
        .background {
            Button { dialogs.dismiss() } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(escapeCloses ? .cancelAction : nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}


// MARK: - 1. Lanes

// The run, in a small panel under the header control that started it: one row per seat,
// what it is doing and for how long, and a way to stop it. Findings still land on the
// Changes screen; this only says how far the reading has got.
struct SecondOpinionLanesPanel: View {
    let reviews: ReviewCommentStore
    let sessionID: UUID
    let lookAt: () -> Void
    let close: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        let runs = reviews.runs(sessionID)
        let running = runs.filter(\.isRunning)
        let findings = reviews.findings(sessionID)
        VStack(alignment: .leading, spacing: Space.md) {
            Text(running.isEmpty ? "Second opinion" : "Reading the changes")
                .font(Typography.body.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if runs.isEmpty {
                Text("No reviewer is at work.").font(Typography.detail).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    lane(run, findings: findings)
                }
            }
            HStack(spacing: Space.md) {
                Text(running.isEmpty ? "Findings wait for you on the Changes tab."
                     : "Findings land on the Changes tab as each one finishes.")
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if running.count > 1 {
                    InlineLink(title: "Stop all", size: Typography.Size.caption, tint: Color.secondary) {
                        reviews.stopSecondOpinion(sessionID)
                        announce("Stopped every review")
                    }
                }
            }
        }
        .padding(Space.card)
        .frame(width: Self.width, alignment: .leading)
        .floatingCard(cornerRadius: Radius.floating)
        .background {
            Button(action: close) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Second opinion progress")
    }

    @ViewBuilder private func lane(_ run: SecondOpinionRun, findings: [ReviewComment]) -> some View {
        let name = run.reviewer.label()
        HStack(alignment: .center, spacing: Space.md) {
            switch run.state {
            case .running:
                BadgedAvatar(agent: run.agent, size: ControlHeight.sm, badge: .working)
                laneWords(name, detail: run.activity, mono: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(from: run.started, to: context.date)).font(Typography.data).foregroundStyle(.tertiary)
                }
                ActionButton(title: "Stop", tone: .sunken, height: ControlHeight.sm, size: Typography.Size.caption,
                             icon: "stop.fill") {
                    reviews.stopSecondOpinion(sessionID, reviewer: run.reviewer)
                    announce("Stopped \(name)'s review")
                }
                .accessibilityLabel("Stop \(name)")
            case .finished(let found):
                BadgedAvatar(agent: run.agent, size: ControlHeight.sm, badge: .done)
                laneWords(name, detail: (found > 0 ? "Found \(found) worth raising" : "Nothing worth raising")
                          + ", took " + clock(from: run.started, to: run.ended ?? Date()))
                if found > 0 {
                    ActionButton(title: "Look", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.caption,
                                 action: lookAt)
                        .accessibilityLabel("Look at what \(name) found")
                }
            case .failed(let message):
                ReviewAvatar(agent: run.agent, size: ControlHeight.sm)
                laneWords(name + " could not finish", detail: message, warns: true)
                ActionButton(title: "Try again", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.caption,
                             icon: "arrow.clockwise") {
                    reviews.retrySecondOpinion(sessionID, reviewer: run.reviewer)
                }
            }
        }
        .padding(.vertical, Space.sm)
        .transition(.fadeIn)
        .accessibilityElement(children: .contain)
    }

    private func laneWords(_ title: String, detail: String, mono: Bool = false, warns: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Typography.label).lineLimit(1)
            Text(detail).font(mono ? Typography.data : Typography.caption)
                .foregroundStyle(warns ? Theme.warningText : Color.secondary)
                .lineLimit(1).truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 3. Findings

struct SecondOpinionFindingsView: View {
    let review: ReviewTarget

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: UUID?
    @State private var editing = false
    @State private var draft = ""
    @State private var keys = WindowKeyHandler()
    @FocusState private var editorFocused: Bool

    init(review: ReviewTarget, selected: UUID?) {
        self.review = review
        _selected = State(initialValue: selected)
    }

    private enum Decision { case kept, dismissed }

    private var store: ReviewCommentStore { review.reviews }
    private var list: [ReviewComment] { SecondOpinionFindings.ordered(store.findings(review.sessionID)) }
    private var dismissedIDs: Set<UUID> { Set(store.dismissedFindings(review.sessionID).map(\.id)) }

    private func decision(_ finding: ReviewComment, dismissed: Set<UUID>) -> Decision? {
        dismissed.contains(finding.id) ? .dismissed : finding.isPending ? nil : .kept
    }

    var body: some View {
        let list = list
        let dismissed = dismissedIDs
        let kept = list.count { decision($0, dismissed: dismissed) == .kept }
        let gone = dismissed.count { id in list.contains { $0.id == id } }
        let left = list.count - kept - gone
        let voices = Set(list.flatMap(\.reviewers))
        let running = unique(store.runs(review.sessionID).filter(\.isRunning).map(\.agent))
        DialogFrame(title: voices.isEmpty ? "Findings" : "Findings from " + names(AgentKind.allCases.filter(voices.contains)),
                    icon: "text.bubble",
                    message: "Keep what you agree with. Kept findings join your review, and nothing reaches \(review.agent.title) until you send it.",
                    escapeCloses: false) {
            if !list.isEmpty { progress(list, dismissed: dismissed, decided: kept + gone) }
        } content: {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !running.isEmpty { waitingNote(running) }
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, finding in
                                if index == 0 || ReviewRound.fileKey(root: list[index - 1].root, path: list[index - 1].path)
                                    != ReviewRound.fileKey(root: finding.root, path: finding.path) {
                                    groupHeader(finding)
                                }
                                row(finding, decision: decision(finding, dismissed: dismissed))
                                    .id(finding.id)
                            }
                        }
                        .padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.lg)
                    }
                    .onChange(of: selected) { _, id in
                        if let id { withAnimation(reduceMotion ? nil : Motion.reveal) { proxy.scrollTo(id) } }
                    }
                }
                .frame(width: 318)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Findings")
                Rectangle().fill(Theme.hairline).frame(width: 1)
                detail(list, dismissed: dismissed, running: running)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 470)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .padding(.top, Space.xl)
        } footer: {
            Text(left > 0 ? "\(kept) kept, \(gone) dismissed, \(left) left. Anything left stays here for later."
                 : "\(kept) kept and added to your review. \(gone) dismissed.")
                .font(Typography.detail).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            ActionButton(title: left > 0 ? "Finish later" : "Done", tone: left > 0 ? .outlined : .green,
                         height: ControlHeight.lg, size: Typography.Size.body) { dialogs.dismiss() }
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            if selected == nil || !list.contains(where: { $0.id == selected }) {
                selected = SecondOpinionFindings.next(after: nil, in: list) { decision($0, dismissed: dismissed) == nil }
                    ?? list.first?.id
            }
            keys.start { handleKey($0) }
        }
        .onDisappear { keys.stop() }
        .onChange(of: list.map(\.id)) { _, ids in
            // A reviewer still at work can bring the first findings in while this is open.
            if selected == nil || !ids.contains(selected!) {
                selected = SecondOpinionFindings.next(after: nil, in: self.list) { decision($0, dismissed: dismissedIDs) == nil }
            }
        }
    }

    private func progress(_ list: [ReviewComment], dismissed: Set<UUID>, decided: Int) -> some View {
        HStack(spacing: Space.md) {
            Text("\(decided) of \(list.count) looked at").font(Typography.detail).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if list.count <= 12 {
                HStack(spacing: Space.xxs) {
                    ForEach(list) { finding in
                        RoundedRectangle(cornerRadius: Radius.tag)
                            .fill(segmentColour(decision(finding, dismissed: dismissed)))
                            .frame(width: 18, height: 5)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .motion(Motion.control, value: decided)
    }

    private func segmentColour(_ decision: Decision?) -> Color {
        switch decision {
        case .kept: Theme.dotOn
        case .dismissed: Color.secondary.opacity(0.5)
        case nil: Theme.field
        }
    }

    private func waitingNote(_ running: [AgentKind]) -> some View {
        HStack(spacing: Space.md) {
            ReviewerSpinner(size: 11)
            Text(running.count == 1 ? "\(running[0].title) is still reading. Its findings will show up here."
                 : "\(names(running)) are still reading. Their findings will show up here.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typography.detail).foregroundStyle(.secondary)
        .padding(.horizontal, Space.md).padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .padding(.horizontal, Space.xs).padding(.top, Space.xs).padding(.bottom, Space.md)
    }

    private func groupHeader(_ finding: ReviewComment) -> some View {
        let folder = (finding.path as NSString).deletingLastPathComponent
        return HStack(spacing: Space.sm) {
            Text((finding.path as NSString).lastPathComponent).font(Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !folder.isEmpty {
                Text(folder).font(Typography.data).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.xs)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ finding: ReviewComment, decision: Decision?) -> some View {
        let isSelected = finding.id == selected
        return Button {
            selected = finding.id
            editing = false
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                severityIcon(finding.severity).frame(width: 16).padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(finding.body.replacingOccurrences(of: "`", with: ""))
                        .font(Typography.detail).lineLimit(2)
                        .strikethrough(decision == .dismissed, color: Color.secondary.opacity(0.5))
                        .foregroundStyle(decision == .dismissed ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(finding.onFile ? "whole file" : "line \(finding.line)").font(Typography.data).foregroundStyle(.tertiary)
                }
                Text(decision == .kept ? "Kept" : decision == .dismissed ? "Dismissed" : "")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(decision == .kept ? Theme.dotOn : Color.secondary)
                    .padding(.top, 1)
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(isSelected ? Theme.accent.opacity(0.09) : .clear))
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, Space.xxs) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .motion(Motion.control, value: decision)
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
        .accessibilityLabel(finding.spokenName + ". " + finding.body
                            + (decision == .kept ? ". Kept" : decision == .dismissed ? ". Dismissed" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func severityIcon(_ severity: ReviewComment.Severity?) -> some View {
        switch severity {
        case .must: Image(systemName: "exclamationmark.triangle.fill").font(Typography.caption).foregroundStyle(Theme.warningText)
        case .should: Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.attention)
        case .look: Image(systemName: "eye").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.tertiary)
        case nil: Image(systemName: "text.bubble").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func detail(_ list: [ReviewComment], dismissed: Set<UUID>, running: [AgentKind]) -> some View {
        if let finding = list.first(where: { $0.id == selected }) {
            let decided = decision(finding, dismissed: dismissed)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.md) {
                        ReviewAvatars(comment: finding, size: 24)
                        Text(finding.voices.first?.name ?? "").font(Typography.body.weight(.semibold))
                        if let other = finding.also.first {
                            Text("and \(other.name) raised this").font(Typography.detail).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let severity = finding.severity { SeverityChip(severity: severity) }
                    }
                    HStack(spacing: Space.sm) {
                        Image(systemName: "doc.text")
                        Text(finding.path)
                        Text(finding.onFile ? "whole file" : "line \(finding.line)").foregroundStyle(.tertiary)
                    }
                    .font(Typography.code).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    codeExcerpt(finding)
                    if editing {
                        TextField("What should change", text: $draft, axis: .vertical)
                            .lineLimit(4...10)
                            .appTextField(size: 14)
                            .focused($editorFocused)
                            .onExitCommand { editing = false }
                            .accessibilityLabel("Edit the finding")
                    } else {
                        ReviewText(text: finding.body, size: 15)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(finding.also.enumerated()), id: \.offset) { _, voice in
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.sm) {
                                ReviewAvatar(agent: voice.agent, size: 16)
                                Text(voice.name).fontWeight(.semibold).foregroundStyle(.primary)
                                Text("on the same lines")
                            }
                            .font(Typography.detail).foregroundStyle(.secondary)
                            ReviewText(text: voice.body, size: 12.5).foregroundStyle(.secondary)
                        }
                        .padding(.leading, Space.md)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
                    }
                    actions(finding, decision: decided, list: list)
                }
                .padding(.horizontal, Space.xxxl).padding(.vertical, Space.xxl)
            }
        } else {
            VStack(spacing: Space.sm) {
                if list.isEmpty && !running.isEmpty {
                    ReviewerSpinner(size: 22)
                    Text("Waiting for the first findings").font(Typography.title)
                    Text("They show up here as soon as a reviewer finishes.")
                } else {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.dotOn)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.dotOn.opacity(0.12)))
                    Text("Nothing left to look at").font(Typography.title).foregroundStyle(.primary).padding(.top, Space.xs)
                    Text("Kept findings are in your review, next to your own comments.")
                }
            }
            .font(Typography.body).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(Space.xxxl)
        }
    }

    @ViewBuilder private func actions(_ finding: ReviewComment, decision: Decision?, list: [ReviewComment]) -> some View {
        HStack(spacing: Space.md) {
            // The outcome and the buttons it replaces swap places: the old set goes at
            // once and the new one fades in, so the two are never drawn over each other.
            Group {
                if let decision {
                    Label(decision == .kept ? "Kept. It is in your review." : "Dismissed. It will not be sent.",
                          systemImage: decision == .kept ? "checkmark" : "xmark")
                        .font(Typography.body)
                    Spacer(minLength: 0)
                    InlineLink(title: "Undo", tint: decision == .kept ? Theme.dotOn : Color.secondary) { undo(finding, decision) }
                } else if editing {
                    ActionButton(title: "Keep my version", tone: .green, height: ControlHeight.md, size: Typography.Size.detail, icon: "checkmark",
                                 shortcut: "⌘↩", keyboardShortcut: KeyboardShortcut(.return, modifiers: .command)) {
                        saveEdit(finding)
                    }
                    .disabled(draft.isBlank)
                    InlineLink(title: "Cancel", tint: Color.secondary) { editing = false }
                } else {
                    ActionButton(title: "Keep", tone: .green, height: ControlHeight.md, size: Typography.Size.detail, icon: "checkmark", shortcut: "K") { keep(finding) }
                    ActionButton(title: "Edit and keep", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail, shortcut: "E") { startEdit(finding) }
                    ActionButton(title: "Dismiss", tone: .sunken, height: ControlHeight.md, size: Typography.Size.detail, shortcut: "D") { dismiss(finding) }
                    Spacer(minLength: 0)
                    GlyphButton(icon: "chevron.up", side: ControlHeight.sm) { move(-1, in: list) }
                        .appTooltip("Previous finding  ↑")
                        .accessibilityLabel("Previous finding")
                    GlyphButton(icon: "chevron.down", side: ControlHeight.sm) { move(1, in: list) }
                        .appTooltip("Next finding  ↓")
                        .accessibilityLabel("Next finding")
                }
            }
            .transition(.fadeIn)
        }
        .padding(decision == nil ? 0 : 10)
        .foregroundStyle(decision == .kept ? Theme.dotOn : Color.secondary)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(decision == .kept ? Theme.dotOn.opacity(0.08)
                                                             : decision == .dismissed ? Theme.field : .clear))
        .padding(.top, Space.xs)
        .motion(Motion.control, value: decision)
    }

    // A few lines around the finding, read from the file, with its own line marked.
    private func codeExcerpt(_ finding: ReviewComment) -> some View {
        let lines = Self.context(for: finding, readFile: store.readFile)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.number) { line in
                HStack(spacing: 0) {
                    Text("\(line.number)").foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing).padding(.trailing, Space.lg)
                    Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Typography.code)
                .frame(height: 19)
                .background(line.number == finding.line ? Theme.attention.opacity(0.16) : .clear)
                .overlay(alignment: .leading) {
                    if line.number == finding.line { Rectangle().fill(Theme.attention).frame(width: 3) }
                }
            }
        }
        .padding(.vertical, Space.sm)
        .surface(Theme.field, cornerRadius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code at line \(finding.line): \(finding.excerpt)")
    }

    static func context(for finding: ReviewComment,
                        readFile: (String) -> String?) -> [(number: Int, text: String)] {
        let fallback = [(number: finding.line, text: finding.excerpt)]
        guard finding.side == .new, !finding.onFile,
              let text = readFile((finding.root as NSString).appendingPathComponent(finding.path)) else { return fallback }
        let all = text.components(separatedBy: "\n")
        guard finding.line >= 1, finding.line <= all.count else { return fallback }
        let first = max(1, finding.line - 2)
        let last = min(all.count, first + 3)
        return (first...last).map { (number: $0, text: all[$0 - 1]) }
    }

    // MARK: Deciding

    private func advance(from id: UUID) {
        selected = SecondOpinionFindings.next(after: id, in: list) { decision($0, dismissed: dismissedIDs) == nil }
    }

    private func keep(_ finding: ReviewComment) {
        store.keep(finding.id, in: review.sessionID)
        announce("Kept. It is in your review.")
        advance(from: finding.id)
    }

    private func dismiss(_ finding: ReviewComment) {
        store.dismiss(finding.id, from: review.sessionID)
        announce("Dismissed. It will not be sent.")
        advance(from: finding.id)
    }

    private func startEdit(_ finding: ReviewComment) {
        draft = finding.body
        editing = true
        editorFocused = true
    }

    private func saveEdit(_ finding: ReviewComment) {
        guard !draft.isBlank else { return }
        store.update(finding.id, body: draft.trimmed, in: review.sessionID)
        editing = false
        announce("Kept with your edits")
        advance(from: finding.id)
    }

    private func undo(_ finding: ReviewComment, _ decision: Decision) {
        switch decision {
        case .kept: store.reopen(finding.id, in: review.sessionID)
        case .dismissed: store.restore(finding, to: review.sessionID)
        }
        selected = finding.id
        announce("Back among the findings to look at")
    }

    private func move(_ step: Int, in list: [ReviewComment]) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected } ?? (step > 0 ? -1 : 0)
        selected = list[(index + step + list.count) % list.count].id
        editing = false
    }

    // K, E and D decide, the arrows move and Escape closes. A key typed into the editor
    // is left to it.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            if editing { editing = false } else { dialogs.dismiss() }
            return true
        case 125: move(1, in: list); return true
        case 126: move(-1, in: list); return true
        default: break
        }
        guard !editing, let finding = list.first(where: { $0.id == selected }),
              decision(finding, dismissed: dismissedIDs) == nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": keep(finding)
        case "e": startEdit(finding)
        case "d": dismiss(finding)
        default: return false
        }
        return true
    }
}
