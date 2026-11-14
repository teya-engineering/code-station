import AppKit
import Observation
import SwiftUI

// Everything about one commit: the message, whether it amends, and how it went. The
// files are the ones picked in the pane when the dialog opened; picking happens there.
@MainActor
@Observable
final class CommitDialogModel {
    // Git's own advice for the length of a summary line, which most tools truncate past.
    static let summaryLimit = 72

    let draft: ChangesCommitDraft
    let files: [GitChange]
    let canAmend: Bool
    let lastSubject: String?
    private(set) var isCommitting = false
    private(set) var error: String?
    @ObservationIgnored private let perform: (_ message: String, _ files: [GitChange], _ amend: Bool) async -> String?

    init(draft: ChangesCommitDraft, files: [GitChange], canAmend: Bool, lastSubject: String?,
         perform: @escaping (_ message: String, _ files: [GitChange], _ amend: Bool) async -> String?) {
        self.draft = draft
        self.files = files
        self.canAmend = canAmend
        self.lastSubject = lastSubject
        self.perform = perform
        // A draft left in amend mode on a branch that has since been pushed would rewrite
        // a published commit.
        if !canAmend { draft.setAmend(false, lastMessage: nil) }
    }

    var amend: Bool {
        get { draft.amend }
        set { draft.setAmend(newValue, lastMessage: lastSubject) }
    }

    var message: String {
        get { draft.message }
        set { draft.message = newValue }
    }

    var summaryLength: Int {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?.count ?? 0
    }

    var summaryTooLong: Bool { summaryLength > Self.summaryLimit }

    var title: String { amend ? "Amend last commit" : "Commit \(counted(files.count, "file"))" }

    var actionTitle: String {
        if isCommitting { return amend ? "Amending…" : "Committing…" }
        return amend ? "Amend commit" : "Commit \(counted(files.count, "file"))"
    }

    var includedLabel: String {
        amend ? "Adds \(counted(files.count, "file"))" : "\(counted(files.count, "file")) included"
    }

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }

    var canCommit: Bool {
        !isCommitting && !message.isBlank && !files.isEmpty && !files.contains { $0.kind == .conflicted }
    }

    // True when the commit landed. On failure the message stays in the draft and the
    // error is shown, so the dialog can stay open for another try.
    @discardableResult
    func commit() async -> Bool {
        guard canCommit else { return false }
        isCommitting = true
        error = nil
        let fold = amend
        let failure = await perform(message.trimmed, files, fold)
        isCommitting = false
        if let failure {
            error = failure
            return false
        }
        draft.didCommit()
        return true
    }
}

struct CommitDialogView: View {
    let model: CommitDialogModel
    let repository: String
    let branch: String
    let committed: (_ amended: Bool) -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var dialogID: UUID?
    @State private var showsFiles = false
    @FocusState private var messageFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(model.title).font(Typography.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("To \(Text(branch).font(Typography.code.weight(.medium)).foregroundStyle(.primary)) in \(repository)")
                        .font(Typography.body).foregroundStyle(Theme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                messageField
                includedFiles
                if model.canAmend { amendOption }
                if let error = model.error { failure(error) }
            }
            .padding(.horizontal, Space.xxl).padding(.top, Space.xxl).padding(.bottom, Space.xl)
            footer
        }
        .background(Theme.card)
        .background(WindowKeyAnchor(handler: keys))
        .motion(Motion.reveal, value: model.error)
        .onAppear {
            dialogID = dialogs.current?.id
            messageFocused = true
            keys.start { handleKey($0) }
        }
        .onDisappear { keys.stop(); dialogs.restoreFocus() }
        .onChange(of: model.error) { _, error in if error != nil { errorFocused = true } }
    }

    private var messageField: some View {
        AppTextEditor(text: Binding(get: { model.message }, set: { model.message = $0 }),
                      placeholder: "Describe what changed. The first line is the summary.", minHeight: 110)
            .focused($messageFocused)
            .disabled(model.isCommitting)
            .accessibilityLabel("Commit message for " + repository)
            .overlay(alignment: .bottomTrailing) {
                Text("\(model.summaryLength) / \(CommitDialogModel.summaryLimit)")
                    .font(Typography.data)
                    .foregroundStyle(model.summaryTooLong ? Theme.warningText : Theme.secondaryText)
                    .padding(.trailing, Space.md).padding(.bottom, Space.sm)
                    .allowsHitTesting(false)
                    .appTooltip("Summary line length. Keep it under \(CommitDialogModel.summaryLimit).")
                    .accessibilityLabel("Summary is \(model.summaryLength) characters"
                        + (model.summaryTooLong ? ", longer than \(CommitDialogModel.summaryLimit)" : ""))
            }
    }

    private var includedFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showsFiles.toggle() } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "chevron.right")
                        .font(Typography.micro).foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(showsFiles ? 90 : 0))
                    Text(model.includedLabel).font(Typography.body.weight(.medium))
                    Spacer(minLength: 0)
                    HStack(spacing: Space.sm) {
                        Text("+\(model.added)").foregroundStyle(Theme.addition)
                        Text("−\(model.removed)").foregroundStyle(Theme.deletion)
                    }.font(Typography.data)
                }
                .padding(.horizontal, Space.lg).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.includedLabel + ", \(model.added) added, \(model.removed) removed lines")
            .accessibilityValue(showsFiles ? "Expanded" : "Collapsed")
            .accessibilityHint("Pick files in the Changes list")
            if showsFiles {
                VStack(spacing: 0) {
                    ForEach(model.files) { file in
                        HStack(spacing: Space.md) {
                            StatusChip(kind: file.kind)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.fileName).font(Typography.detail.weight(.medium)).lineLimit(1)
                                Text((file.path as NSString).deletingLastPathComponent)
                                    .font(Font.system(size: Typography.Size.micro)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if file.isBinary {
                                Text("binary").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                            } else {
                                HStack(spacing: Space.sm) {
                                    Text("+\(file.added ?? 0)").foregroundStyle(Theme.addition)
                                    Text("−\(file.removed ?? 0)").foregroundStyle(Theme.deletion)
                                }.font(Typography.data)
                            }
                        }
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        .appTooltip(file.path)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.bottom, Space.sm)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .background(Theme.field.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.border))
        .motion(Motion.reveal, value: showsFiles)
    }

    private var amendOption: some View {
        Toggle(isOn: Binding(get: { model.amend }, set: { model.amend = $0 })) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Amend last commit").font(Typography.body.weight(.medium))
                Text(model.lastSubject.map { "Add these files to “\($0)” instead of making a new commit." }
                     ?? "Add these files to the last commit instead of making a new one.")
                    .font(Typography.detail).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.appCheckbox)
        .disabled(model.isCommitting)
    }

    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(model.amend ? "Could not amend the commit" : "Could not create the commit")
                .font(Typography.body.weight(.semibold))
            ScrollView {
                Text(error).font(Typography.data).foregroundStyle(Theme.terminalText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.terminal, in: RoundedRectangle(cornerRadius: Radius.control))
            Text("Your message is kept. Fix the problem, then commit again.").font(Typography.detail)
        }
        .foregroundStyle(Theme.warningText)
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityFocused($errorFocused)
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Group {
                if model.isCommitting {
                    ChangesProgressLabel(title: model.amend ? "Amending…" : "Committing…")
                } else {
                    Label("Stays on this Mac until you push.", systemImage: "lock")
                }
            }
            .font(Typography.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Spacer(minLength: 0)
            ActionButton(title: "Cancel", tone: .sunken) { dialogs.dismiss() }
                .disabled(model.isCommitting)
            ActionButton(title: model.actionTitle, tone: .green,
                         icon: model.isCommitting ? "hourglass" : nil,
                         shortcut: model.isCommitting ? nil : "⌘ ↵") { commit() }
                .disabled(!model.canCommit)
                .motion(Motion.reveal, value: model.isCommitting)
        }
        .padding(.vertical, Space.lg).padding(.leading, Space.xxl).padding(.trailing, Space.lg)
        .background(Theme.field)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func commit() {
        let amended = model.amend
        Task {
            guard await model.commit() else { return }
            dialogs.dismiss()
            committed(amended)
        }
    }

    // The editor takes Return for a new line, so the dialog's own keys go through the
    // window: Command-Return commits, Escape cancels.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current?.id == dialogID else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { dialogs.dismiss(); return true }
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            commit()
            return true
        }
        return false
    }
}
