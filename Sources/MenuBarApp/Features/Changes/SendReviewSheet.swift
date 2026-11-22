import SwiftUI

// The send dialog's body: a checklist by file, a note for the round, and on request the
// exact words the agent will read. Anything unticked stays in the review.
struct SendReviewSheet: View {
    let agentTitle: String
    let comments: [ReviewComment]
    let pendingCount: Int
    let busy: Bool
    // Questions asked on the Changes screen whose answers do not go with this message.
    var questionsLeftOut = 0
    let fileName: (ReviewComment) -> String
    let prompt: ([ReviewComment], String) -> String
    let lookFirst: () -> Void
    let send: ([ReviewComment], String) -> Void

    @Environment(DialogPresenter.self) private var dialogs
    @State private var picked: Set<UUID>
    @State private var note = ""
    @State private var showsPrompt = false
    // The checklist is as tall as what it lists, up to a cap, rather than always the cap.
    @State private var listHeight: CGFloat = 120

    init(agentTitle: String, comments: [ReviewComment], pendingCount: Int, busy: Bool,
         questionsLeftOut: Int = 0, startsOnMessage: Bool = false,
         fileName: @escaping (ReviewComment) -> String,
         prompt: @escaping ([ReviewComment], String) -> String,
         lookFirst: @escaping () -> Void, send: @escaping ([ReviewComment], String) -> Void) {
        self.agentTitle = agentTitle
        self.comments = comments
        self.pendingCount = pendingCount
        self.busy = busy
        self.questionsLeftOut = questionsLeftOut
        self.fileName = fileName
        self.prompt = prompt
        self.lookFirst = lookFirst
        self.send = send
        _picked = State(initialValue: Set(comments.map(\.id)))
        _showsPrompt = State(initialValue: startsOnMessage)
    }

    private var chosen: [ReviewComment] { comments.filter { picked.contains($0.id) } }

    private var groups: [(file: String, comments: [ReviewComment])] {
        var result: [(file: String, comments: [ReviewComment])] = []
        for comment in comments {
            let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
            if let index = result.firstIndex(where: { $0.file == key }) {
                result[index].comments.append(comment)
            } else {
                result.append((key, [comment]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if pendingCount > 0 {
                callout(icon: "exclamationmark.triangle.fill", tint: Theme.attentionText, fill: Theme.attention.opacity(0.12),
                        bold: "\(counted(pendingCount, "finding")) still to look at.",
                        text: (pendingCount == 1 ? "It is" : "They are") + " not part of this review and will wait here.") {
                    InlineLink(title: "Look first", tint: Theme.attentionText) {
                        dialogs.dismiss()
                        lookFirst()
                    }
                }
            }
            if busy {
                callout(icon: "clock", tint: Theme.plan, fill: Theme.plan.opacity(0.1),
                        bold: "\(agentTitle) is in the middle of a turn.",
                        text: "Your review goes in as soon as it ends, so nothing it is doing now is interrupted.") {
                    EmptyView()
                }
            }
            HStack(spacing: Space.xs) {
                ChoicePill(title: "Comments \(chosen.count)", selected: !showsPrompt) { showsPrompt = false }
                ChoicePill(title: "What \(agentTitle) reads", selected: showsPrompt) { showsPrompt = true }
                Spacer(minLength: 0)
                if !showsPrompt {
                    InlineLink(title: picked.count == comments.count ? "Untick all" : "Tick all", tint: Color.secondary) {
                        picked = picked.count == comments.count ? [] : Set(comments.map(\.id))
                    }
                }
            }
            ScrollView {
                if showsPrompt {
                    Text(chosen.isEmpty ? "Tick at least one comment to send." : prompt(chosen, note))
                        .font(Typography.data)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                } else {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        ForEach(groups, id: \.file) { group in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                HStack(spacing: Space.sm) {
                                    Text(fileName(group.comments[0])).font(Typography.label)
                                    Text(counted(group.comments.count, "comment"))
                                        .font(Typography.caption).foregroundStyle(.tertiary)
                                }
                                ForEach(group.comments) { comment in row(comment) }
                            }
                        }
                    }
                    .padding(Space.lg)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
            }
            .frame(height: min(300, listHeight))
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
            if questionsLeftOut > 0 {
                Label(questionsLeftOut == 1 ? "Your question and its answer are left out. They stay in Changes."
                      : "Your \(questionsLeftOut) questions and their answers are left out. They stay in Changes.",
                      systemImage: "eye.slash")
                    .font(Typography.detail).foregroundStyle(Theme.plan)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Anything else for this round?").font(Typography.label)
                TextField("For example: run the tests when you are done", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .appTextField()
            }
            HStack(spacing: Space.lg) {
                Spacer(minLength: 0)
                Button { dialogs.dismiss() } label: {
                    Text("Cancel").font(Typography.label).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .hoverLift()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                ActionButton(title: "\(busy ? "Queue" : "Send") \(counted(chosen.count, "comment"))",
                             tone: .green, height: ControlHeight.lg, size: Typography.Size.body, icon: "paperplane.fill",
                             keyboardShortcut: .defaultAction) {
                    let list = chosen
                    let words = note
                    dialogs.dismiss()
                    send(list, words)
                }
                .disabled(chosen.isEmpty)
            }
            .padding(.top, Space.xs)
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(comment.id) },
                             set: { on in if on { picked.insert(comment.id) } else { picked.remove(comment.id) } })) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    ReviewAvatars(comment: comment, size: 16)
                    Text(comment.authorName).font(Typography.label)
                    Text(comment.linesLabel).font(Typography.data).foregroundStyle(.secondary)
                    if comment.kind == .question { QuestionTag() }
                    if let severity = comment.severity { SeverityChip(severity: severity) }
                }
                ReviewText(text: comment.body, size: 12, lineLimit: 3)
            }
            .padding(.top, -2)
        }
        .toggleStyle(.appCheckbox)
        .accessibilityLabel(comment.spokenName + ". " + comment.body)
    }

    private func callout<Action: View>(icon: String, tint: Color, fill: Color, bold: String, text: String,
                                       @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon).foregroundStyle(tint)
            (Text(bold).fontWeight(.semibold) + Text(" " + text))
                .font(Typography.detail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .foregroundStyle(tint)
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(fill))
    }
}
