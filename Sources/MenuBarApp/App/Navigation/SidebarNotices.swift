import SwiftUI
import CodeStationCore

// A session worth naming above the tree, and the few words that say why. The same list
// feeds the NEEDS YOU card and the running count.
struct NoticedSession {
    let session: ChatSession
    let project: Project
    let notice: SessionNotice
    // Why this one is here, in the few words that fit under its title: the tool that is
    // asking, or what the finished turn left behind.
    let reason: String
}

@MainActor
enum SidebarNotices {
    // Reads each session's state but never the tool it is running. A tool starts and
    // ends many times a turn, and this list is built with the whole rail, so reading it
    // here would redraw the rail on every call.
    static func all(store: ProjectStore, runner: SessionRunner) -> [NoticedSession] {
        store.sidebarSessions.compactMap { session in
            guard let project = store.project(session.projectID) else { return nil }
            let live = LiveConversation.id(of: session.id, store: store, runner: runner)
            let question = runner.question(live)
            guard let notice = SessionNotice(
                isBusy: runner.state(live).isBusy || runner.isAskingSecondOpinion(session.id),
                needsInput: question != nil,
                finishedUnseen: store.hasFinished(session.id)) else { return nil }
            return NoticedSession(session: session, project: project, notice: notice,
                                  reason: reason(notice, question: question))
        }
        .sorted(by: comesFirst)
    }

    // Whatever is waiting on a person leads, since that is the only kind anyone has to
    // act on. Within a kind the session touched most recently leads, so the rail reads
    // newest first the way the cards under it do.
    static func comesFirst(_ first: NoticedSession, _ second: NoticedSession) -> Bool {
        if first.notice != second.notice { return first.notice.rawValue < second.notice.rawValue }
        return first.session.lastActivity > second.session.lastActivity
    }

    static func reason(_ notice: SessionNotice, question: PermissionRequest?) -> String {
        notice.reason(question: question)
    }
}

// MARK: - The rail's header

// The app's own row: home and the few numbers worth carrying at the very top. The running
// count is the reason to look at the rail at all, so it sits here rather than being found
// by opening the project it belongs to. Phone sharing reads as a second status line in the
// same box; stopping a share belongs to the pairing dialog, not to the rail.
struct SidebarBrandBar: View {
    let runningCount: Int
    let isHome: Bool
    let selectHome: () -> Void

    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MobileAccessController.self) private var mobileAccess
    @State private var hovering = false
    @State private var pointer = CGPoint(x: 0.6, y: -0.4)
    @State private var headerSize = CGSize.zero
    @FocusState private var focused: Bool

    private var phone: SidebarPhoneStatus? { SidebarPhoneStatus(mobileAccess.share) }

    var body: some View {
        Button(action: selectHome) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    brand
                    Spacer(minLength: 0)
                    statusLines
                }
                VStack(alignment: .leading, spacing: 8) {
                    brand
                    HStack {
                        Spacer(minLength: 0)
                        statusLines
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isHome || hovering ? Theme.field : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { headerSize = $0 }
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                pointer = CGPoint(x: min(1, max(-1, point.x / max(1, headerSize.width) * 2 - 1)),
                                  y: min(1, max(-1, point.y / max(1, headerSize.height) * 2 - 1)))
            }
        }
        .sidebarFocusRing($focused)
        .accessibilityLabel("Teya Code Station home")
        .accessibilityValue(Self.accessibilityValue(runningCount: runningCount, phone: phone))
        .accessibilityAddTraits(isHome ? .isSelected : [])
    }

    static func accessibilityValue(runningCount: Int, phone: SidebarPhoneStatus?) -> String {
        [runningCount > 0 ? "\(runningCount) running sessions" : nil, phone?.spoken]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var brand: some View {
        HStack(spacing: 9) {
            SidebarBrandMark(input: .init(hovered: hovering,
                                          focused: focused && KeyboardFocusVisibility.shared.isVisible,
                                          pointer: hovering ? pointer : CGPoint(x: 0.6, y: -0.4),
                                          reducedMotion: reduceMotion))
                .frame(width: 41, height: 41)
                .frame(width: 33, height: 33)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Teya")
                    .font(.logo(9 * max(1, textScale), weight: 500))
                    .foregroundStyle(.secondary)
                Text("Code Station")
                    .font(.logo(15 * max(1, textScale)))
                    .kerning(-0.55)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var statusLines: some View {
        if runningCount > 0 || phone != nil {
            VStack(alignment: .trailing, spacing: 4) {
                if runningCount > 0 {
                    HStack(spacing: 5) {
                        RunningDot(size: 5)
                        Text("\(runningCount) running")
                    }
                    .foregroundStyle(Theme.accent)
                }
                if let phone {
                    HStack(spacing: 5) {
                        Image(systemName: phone.isConnected
                                ? "iphone.radiowaves.left.and.right" : "iphone")
                        Text(phone.text)
                    }
                    .foregroundStyle(phone.isConnected ? Theme.addition : Theme.accent)
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .fixedSize()
        }
    }
}

// What the brand bar says about the code that is out. It counts as on the phone once a
// phone has joined it; until then it is only shared.
struct SidebarPhoneStatus: Equatable {
    let isConnected: Bool

    init?(_ share: MobileShare?) {
        guard let share else { return nil }
        isConnected = share.isConnected
    }

    init(isConnected: Bool) {
        self.isConnected = isConnected
    }

    var text: String { isConnected ? "On phone" : "Shared" }

    var spoken: String { isConnected ? "shared with a connected phone" : "shared with a phone, none connected" }
}

// Permission prompts and turns that ended while the user was away are the only things in
// the app that are waiting on a person, so they sit above the tree rather than being
// found by opening the project they happen to belong to. They take one row as a stack,
// with the newest on top, and fan out into a list while the pointer rests on them.
// Shown only when there is something waiting; the sidebar leaves it out otherwise.
struct SidebarNeedsYouStack: View {
    let waiting: [NoticedSession]
    let open: (ChatSession) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fanned = false
    @State private var intent: Task<Void, Never>?

    private static let cardHeight: CGFloat = 56
    private static let pitch: CGFloat = 62
    // How far each card behind the top one shows below it, and how many show at all.
    private static let peek: CGFloat = 6
    private static let behind = 2
    // The pointer has to settle for this long before the stack opens, so one passing over
    // on its way to the tree does not shove the tree down and back.
    private static let hoverIntent: Duration = .milliseconds(140)
    private static let resize: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.38)

    private var fans: Bool { fanned && waiting.count > 1 }

    private var height: CGFloat {
        fans ? CGFloat(waiting.count) * Self.pitch - (Self.pitch - Self.cardHeight)
             : Self.cardHeight + CGFloat(min(waiting.count - 1, Self.behind)) * Self.peek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            ZStack(alignment: .top) {
                ForEach(Array(waiting.enumerated()), id: \.element.session.id) { index, noticed in
                    card(noticed, at: index)
                }
            }
            .frame(height: height, alignment: .top)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Self.resize, value: height)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .onHover(perform: hover)
        .onDisappear { intent?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs you, \(waiting.count)")
    }

    private var heading: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.attention).frame(width: 6, height: 6)
            Text("Needs you")
                .font(.system(size: 11.5, weight: .bold))
            Text(verbatim: "\(waiting.count)")
                .font(.mono(11.5, .bold))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Motion.pop, value: waiting.count)
            Spacer(minLength: 6)
            Text("⌘⇧A")
                .font(.mono(9.5))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.attentionText)
        .padding(.horizontal, 4)
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
    }

    // The cards behind the top one step in from the sides rather than shrinking, since a
    // card holds a button and a scaled button is one AppKit cannot lay out.
    private func card(_ noticed: NoticedSession, at index: Int) -> some View {
        let depth = min(index, Self.behind)
        let shown = fans || index <= Self.behind
        return NeedsYouStackCard(noticed: noticed, open: open)
            .padding(.horizontal, fans ? 0 : CGFloat(depth) * 7)
            .offset(y: fans ? CGFloat(index) * Self.pitch : CGFloat(depth) * Self.peek)
            .opacity(shown ? (fans ? 1 : 1 - Double(depth) * 0.22) : 0)
            .zIndex(Double(waiting.count - index))
            .allowsHitTesting(fans || index == 0)
            .animation(reduceMotion ? nil : .timingCurve(0.3, 1.25, 0.5, 1, duration: 0.42)
                .delay(fans ? Double(index) * 0.03 : 0), value: fans)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .offset(y: -16).combined(with: .opacity),
                removal: .offset(x: 40).combined(with: .opacity)))
            .animation(reduceMotion ? nil : .timingCurve(0.3, 1.25, 0.5, 1, duration: 0.42),
                       value: index)
    }

    private func hover(_ inside: Bool) {
        intent?.cancel()
        guard inside else {
            setFanned(false)
            return
        }
        intent = Task {
            try? await Task.sleep(for: Self.hoverIntent)
            guard !Task.isCancelled else { return }
            setFanned(true)
        }
    }

    // The animation on the stack's own frame only reaches views inside it. The change has
    // to be animated where it is made, or the tree under the stack jumps to its new place
    // while the stack is still growing or shrinking above it.
    private func setFanned(_ value: Bool) {
        withAnimation(reduceMotion ? nil : Self.resize) { fanned = value }
    }
}

private struct NeedsYouStackCard: View {
    let noticed: NoticedSession
    let open: (ChatSession) -> Void

    @Environment(ProjectStore.self) private var store
    @State private var hovering = false

    // Answering means the pending prompt; reviewing means the files a finished turn left
    // behind, so the two land on different tabs of the same session.
    private var answering: Bool { noticed.notice == .needsInput }

    var body: some View {
        HStack(spacing: 9) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(noticed.session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(noticed.reason)
                    .font(.mono(10))
                    .foregroundStyle(Theme.attentionText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ActionButton(title: answering ? "Answer" : "Review", height: 24, size: 11.5) {
                open(noticed.session)
            }
            .accessibilityLabel("\(answering ? "Answer" : "Review") \(noticed.session.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Theme.attention.opacity(hovering ? 0.8 : 0.5),
                          lineWidth: hovering ? 1.4 : 1.2))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.05), radius: hovering ? 6 : 1,
                y: hovering ? 4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { open(noticed.session) }
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(noticed.session.title)
        .accessibilityValue(noticed.reason)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(noticed.session) }
    }

    @ViewBuilder private var tile: some View {
        if let workspace = noticed.session.workspaceID.flatMap(store.workspace) {
            SidebarIdentityTile(avatar: workspace.sidebarAvatar, name: workspace.name,
                                tint: Theme.workspaceTint, stacked: true, side: 22)
        } else {
            SidebarIdentityTile(avatar: noticed.project.sidebarAvatar,
                                name: noticed.project.name,
                                tint: Theme.projectTint(for: noticed.project.name),
                                dashed: noticed.project.kind == .adHoc, side: 22)
        }
    }
}
