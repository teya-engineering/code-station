import SwiftUI

// What a second opinion asked from a session can be about. Each one reads something
// different and lands somewhere different: a card under the answer, findings on the
// diff, pins on the design.
enum SessionOpinionKind: Hashable {
    case chat, changes, design
}

// What the person settled on in the ask dialog, for the kind they picked.
enum SessionOpinionChoice {
    case chat([SecondOpinion.Reviewer], [ChatSecondOpinion.Focus], ChatSecondOpinion.Reading)
    case changes([SecondOpinion.Reviewer], Set<SecondOpinion.Focus>, SecondOpinionScopeChoice)
    case design([SecondOpinion.Reviewer], [DesignSecondOpinion.Focus], DesignSecondOpinion.Reading)
}

// One ask dialog for everything a session can be judged on. The person picks what to
// review first, and the rest of the dialog follows that pick. A kind with nothing to read
// yet stays in the row, turned off, so the row keeps its shape and says what is possible.
struct SessionOpinionAsk: View {
    struct Answer {
        var subject: ChatSecondOpinion.Subject
        var author: SecondOpinion.Reviewer
        // The answer the person pointed at, rather than the latest one.
        var picked: Bool
    }

    struct Changes {
        var author: SecondOpinion.Reviewer
        var running: Set<SecondOpinion.Reviewer>
        var fileCount: Int
        var fileName: String?
        var canReadSince: Bool
    }

    struct Design {
        var author: SecondOpinion.Reviewer
        var screenCount: Int
    }

    let answer: Answer?
    let changes: Changes?
    let design: Design?
    let installed: [AgentKind]
    let ask: (SessionOpinionChoice) -> Void

    @State private var kind: SessionOpinionKind
    @State private var lineup: [SecondOpinion.Reviewer]
    @State private var chatFocus = Set(ChatSecondOpinion.Focus.standard)
    @State private var chatReading = ChatSecondOpinion.Reading()
    @State private var changesFocus: Set<SecondOpinion.Focus>
    @State private var scope: SecondOpinionScopeChoice
    @State private var designFocus = Set(DesignSecondOpinion.Focus.standard)
    @State private var designReading = DesignSecondOpinion.Reading()
    @Namespace private var track
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(answer: Answer?, changes: Changes?, design: Design?, initial: SessionOpinionKind,
         installed: [AgentKind], lineup: [SecondOpinion.Reviewer],
         changesFocus: Set<SecondOpinion.Focus>, scope: SecondOpinionScopeChoice,
         ask: @escaping (SessionOpinionChoice) -> Void) {
        self.answer = answer
        self.changes = changes
        self.design = design
        self.installed = installed
        self.ask = ask
        _kind = State(initialValue: initial)
        _lineup = State(initialValue: lineup)
        _changesFocus = State(initialValue: changesFocus)
        var scope = scope
        if scope == .sinceReview, changes?.canReadSince != true { scope = .all }
        if scope == .file, changes?.fileName == nil { scope = .all }
        _scope = State(initialValue: scope)
    }

    var body: some View {
        SecondOpinionAskView(
            message: message, safety: safety, author: author, authorDid: authorDid,
            installed: installed, running: kind == .changes ? changes?.running ?? [] : [],
            lineup: $lineup, needsFocus: kind == .changes && changesFocus.isEmpty,
            subject: { picker },
            choices: {
                choices
                    .id(kind)
                    .transition(reduceMotion ? .opacity : .fadeIn)
            },
            ask: {
                switch kind {
                case .chat:
                    ask(.chat(lineup, ChatSecondOpinion.Focus.allCases.filter(chatFocus.contains), chatReading))
                case .changes:
                    ask(.changes(lineup, changesFocus, scope))
                case .design:
                    ask(.design(lineup, DesignSecondOpinion.Focus.allCases.filter(designFocus.contains), designReading))
                }
            })
        .motion(Motion.reveal, value: kind)
    }

    private var picker: some View {
        SecondOpinionSection(title: "What to review") {
            HStack(spacing: Space.xxs) {
                kindPill(.chat, title: answer.map { answerTitle($0) } ?? "The last answer",
                         detail: answer.map { _ in "And what you asked" } ?? "No answer yet",
                         enabled: answer != nil)
                kindPill(.changes, title: "The changes",
                         detail: changes.map { counted($0.fileCount, "file") } ?? "Nothing changed yet",
                         enabled: changes != nil)
                kindPill(.design, title: "The design",
                         detail: design.map { counted($0.screenCount, "screen") } ?? "No design yet",
                         enabled: design != nil)
            }
            .padding(Space.xxs)
            .fieldSurface(cornerRadius: Radius.card)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What to review")
        }
    }

    private func answerTitle(_ answer: Answer) -> String {
        if answer.subject.kind == .plan { return "This plan" }
        return answer.picked ? "This answer" : "The last answer"
    }

    private func kindPill(_ choice: SessionOpinionKind, title: String, detail: String, enabled: Bool) -> some View {
        ChoicePill(title: title, selected: kind == choice, enabled: enabled, thumb: track,
                   detail: detail, fills: true) {
            withAnimation(reduceMotion ? nil : Motion.control) { kind = choice }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(kind == choice ? .isSelected : [])
    }

    @ViewBuilder
    private var choices: some View {
        switch kind {
        case .chat:
            ChatOpinionChoices(authorTitle: author.agent.title, focus: $chatFocus, reading: $chatReading)
        case .changes:
            ChangesOpinionChoices(focus: $changesFocus, scope: $scope, fileCount: changes?.fileCount ?? 0,
                                  fileName: changes?.fileName, canReadSince: changes?.canReadSince ?? false)
        case .design:
            DesignOpinionChoices(focus: $designFocus, reading: $designReading)
        }
    }

    // MARK: Wording

    private var author: SecondOpinion.Reviewer {
        switch kind {
        case .chat: answer?.author ?? changes?.author ?? design?.author ?? .init(agent: .claudeCode)
        case .changes: changes?.author ?? answer?.author ?? .init(agent: .claudeCode)
        case .design: design?.author ?? answer?.author ?? .init(agent: .claudeCode)
        }
    }

    private var authorDid: String {
        switch kind {
        case .chat: "wrote this \(answer?.subject.noun ?? "answer")"
        case .changes: "wrote these changes"
        case .design: "drew this design"
        }
    }

    private var message: String {
        let title = author.agent.title
        switch kind {
        case .chat where answer?.subject.kind == .plan:
            return "Agents that did not write this plan check it before anything changes. You pick which points reach \(title)."
        case .chat:
            return "Agents that did not write this answer check it on their own. You pick which points reach \(title)."
        case .changes:
            return "Agents that did not write these changes read them on their own and leave findings. You decide which ones reach \(title)."
        case .design:
            return "Agents that did not draw this design look at every screen, light and dark, and pin notes where they see a problem. You pick which notes go back."
        }
    }

    private var safety: String {
        let title = author.agent.title
        switch kind {
        case .chat:
            return "Read-only, and without your MCP servers. \(title) sees nothing they say until you send it."
        case .changes:
            return "Reviewers can read files but not change them, and run without your MCP servers. They see the diff, not this conversation."
        case .design:
            return "They look and read. They cannot change the design or use your MCP servers."
        }
    }
}
