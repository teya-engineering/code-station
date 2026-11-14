import SwiftUI

// The reviews on the pull request this session's branch is on, grouped by reviewer. Every
// button that sends something to GitHub or pushes a commit is on this screen and acts on
// one thread.
struct PullRequestReviewsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(PullRequestReviewStore.self) private var reviews
    let sessionID: UUID
    let openChanges: () -> Void

    @State private var failure: String?
    @State private var showing: PullRequestReviewerFilter = .everyone
    @State private var note: String?
    @State private var noteIcon = "arrow.up.forward.app"
    @State private var notes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [PullRequestReviewStore.Loaded] { reviews.loaded[sessionID] ?? [] }
    private var isLoading: Bool { reviews.loading.contains(sessionID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let message = failure ?? reviews.errors[sessionID] {
                    WarningStrip(message) {
                        if failure != nil { GlyphButton(icon: "xmark", side: ControlHeight.xs) { failure = nil } }
                    }
                    .surface(Theme.warningBackground, cornerRadius: Radius.card, border: .clear)
                    .transition(.fold)
                }
                if !entries.isEmpty { filterRow }
                ForEach(entries, id: \.pullRequest.url) { entry in
                    PullRequestCard(entry: entry, sessionID: sessionID, showing: showing,
                                    openChanges: openChanges, failed: { failure = $0 })
                }
                if entries.isEmpty { emptyState }
            }
            .padding(Space.xxl)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            // Only a failure the person can dismiss moves the page. An error from a
            // background read just appears.
            .smoothlyResizes(when: failure)
        }
        .background(Theme.background)
        .environment(\.showExternalNote, ExternalNote(showNote))
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let note {
                    HeaderNote(icon: noteIcon, text: note)
                        .padding(.top, Space.lg).padding(.trailing, Space.xxl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
    }

    // A second note keeps the line up rather than letting the first one's timer take it
    // down early.
    private func showNote(_ text: String, icon: String) {
        notes += 1
        let shown = notes
        noteIcon = icon
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if notes == shown { note = nil }
        }
    }

    private var filterRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(PullRequestReviewerFilter.allCases, id: \.self) { filter in
                ChoicePill(title: filter.title, selected: showing == filter) { showing = filter }
            }
            Spacer(minLength: 0)
            GlyphButton(icon: "arrow.clockwise", side: ControlHeight.sm, active: isLoading) {
                Task { await reviews.load(sessionID, store: store) }
            }
            .appTooltip("Read GitHub again")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            if isLoading {
                LoopSpinner(size: 14)
                Text("Looking for a pull request on this branch…").font(Typography.body).foregroundStyle(.secondary)
            } else {
                Text("No pull request yet.").font(Typography.body.weight(.semibold))
                Text("Reviews land here once this session's branch has a pull request.")
                    .font(Typography.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }
}

// One pull request: its name and state, then its reviewers, each behind a fold.
private struct PullRequestCard: View {
    @Environment(\.showExternalNote) private var showExternalNote
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let showing: PullRequestReviewerFilter
    let openChanges: () -> Void
    let failed: (String) -> Void

    private var groups: [PullRequestReviewerGroup] { PullRequestReviewerGroup.grouping(entry.reviews, showing: showing) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if groups.isEmpty {
                Text("No reviews here yet.").font(Typography.body).foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                PullRequestReviewerGroupView(group: group, entry: entry, sessionID: sessionID,
                                             openChanges: openChanges, failed: failed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.xl)
        .surface(Theme.card, cornerRadius: Radius.floating)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(verbatim: "#\(entry.pullRequest.number)").font(Font.mono(Typography.Size.body, .semibold))
            Text(entry.status.title).font(Typography.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if !entry.isOpen {
                MonoChip(text: entry.status.state == .merged ? "MERGED" : "CLOSED", size: Typography.Size.micro,
                         tint: entry.status.state == .merged ? Theme.dotOnText : nil)
            }
            Spacer(minLength: 8)
            Text(entry.status.headBranch).font(Typography.data).foregroundStyle(.secondary).lineLimit(1)
            GlyphButton(icon: "arrow.up.right.square", side: ControlHeight.sm) {
                guard let url = URL(string: entry.pullRequest.url) else { return }
                NSWorkspace.shared.open(url)
                showExternalNote("Opened on GitHub", "arrow.up.forward.app")
            }
            .appTooltip("Open on GitHub")
        }
    }
}
