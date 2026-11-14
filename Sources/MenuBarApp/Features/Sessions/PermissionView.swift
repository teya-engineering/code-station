import SwiftUI

// The agent waiting on the person, at the foot of the transcript. A tool asking for
// permission and a question with options are the same thing on the wire, but not to read:
// one is a yes or no about something about to happen, the other is a choice being asked
// for, so each gets its own card.
struct PermissionCard: View {
    @Environment(\.textScale) private var textScale

    let request: PermissionRequest
    // The folders the session already has a view of, which is what says whether this call
    // is being asked about because of where it reaches rather than what it does.
    var workingDirectories: [String] = []
    // Where a subject written as markdown resolves the files it links to.
    var projectPath: String = ""
    // Opens the second opinion ask dialog on a plan. Nil where there is no plan to judge.
    var secondOpinion: (() -> Void)? = nil
    let onAnswer: (PermissionAnswer) -> Void

    var body: some View {
        if request.isQuestion {
            QuestionCard(request: request, onAnswer: onAnswer)
        } else {
            approval
        }
    }

    private var outside: String? { request.directoryOutside(workingDirectories) }

    // The button carries the folder's own name; the line above it carries the whole path,
    // which is where the reader checks it is the folder they think it is.
    private func name(of directory: String) -> String {
        URL(fileURLWithPath: directory).lastPathComponent
    }

    // A plan is a page to read before answering, so it is drawn in the same type the
    // transcript draws prose in rather than as a line of JSON. It is capped and scrolls,
    // because a plan long enough to fill the window would push its own buttons off it.
    private var document: some View {
        ScrollView {
            MarkdownProse(text: request.subject,
                          projectPath: projectPath,
                          textScale: textScale) { segment in
                MarkdownCodeBlock(segment: segment)
                    .equatable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
        }
        .frame(maxHeight: 340 * textScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.control, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                Image(systemName: "hand.raised.fill")
                    .font(Typography.detail)
                Text("\(request.title) needs permission")
                    .font(Typography.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.warningText)

            // The description explains the intent, the subject is what will actually run.
            // Both are worth having, but only one of them can be checked.
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if request.subjectIsMarkdown {
                document
            } else if !request.subject.isEmpty {
                Text(request.subject)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
            }

            // Nearly every repeat of the same question comes from a call reaching outside
            // the session's folders. Saying so turns a prompt that looks arbitrary - six
            // identical commands went through, this one did not - into one with an
            // obvious answer, and the answer is the next button along.
            if let outside {
                Text("Reaches \(outside.abbreviatedPath), outside this session's folders.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.md) {
                CardButton(title: "Allow", prominent: true) { onAnswer(.allowOnce) }
                // The folder takes the place of "always allow" rather than sitting beside
                // it, because when the folder is the reason it is also the better answer:
                // allowing the whole tool everywhere is a far wider yes than the question
                // being asked, and it would not stop the next call into the same folder.
                if let outside {
                    CardButton(title: "Allow, and add \(name(of: outside))") {
                        onAnswer(.allowAddingDirectory(outside))
                    }
                } else if let always = request.alwaysTitle {
                    CardButton(title: always) { onAnswer(.allowAlways) }
                }
                Spacer(minLength: 0)
                if request.subjectIsMarkdown, let secondOpinion {
                    SecondOpinionButton(usual: Preferences.secondOpinionLineup().map(\.agent),
                                        action: secondOpinion)
                        .appTooltip("Ask other agents to check this plan before anything changes")
                }
                CardButton(title: "Deny") { onAnswer(.deny) }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.warningBackground, cornerRadius: Radius.floating,
                 border: Theme.warningText.opacity(0.25))
    }
}

private struct QuestionCard: View {
    let request: PermissionRequest
    let onAnswer: (PermissionAnswer) -> Void

    // Question text to what is picked so far. Multi-select keeps a set, a single choice
    // keeps the one label, and typed text replaces both.
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]
    @State private var currentQuestionIndex = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if request.questions.count > 1 {
                questionTabs
            }

            question(request.questions[currentQuestionIndex])

            HStack(spacing: Space.md) {
                CardButton(title: "Skip", tint: Theme.accent) { onAnswer(.deny) }
                Spacer(minLength: 0)
                if currentQuestionIndex > 0 {
                    CardButton(title: "Back", tint: Theme.accent) {
                        showQuestion(at: currentQuestionIndex - 1)
                    }
                }
                if isLastQuestion {
                    CardButton(title: "Submit", tint: Theme.accent, prominent: true) {
                        onAnswer(.answers(answers))
                    }
                    .disabled(!isComplete)
                    .opacity(isComplete ? 1 : 0.45)
                } else {
                    CardButton(title: "Next", tint: Theme.accent, prominent: true) {
                        showQuestion(at: currentQuestionIndex + 1)
                    }
                    .disabled(!isCurrentQuestionComplete)
                    .opacity(isCurrentQuestionComplete ? 1 : 0.45)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.accent.opacity(0.06), cornerRadius: Radius.floating,
                 border: Theme.accent.opacity(0.25))
    }

    private var questionTabs: some View {
        HStack(spacing: Space.xs) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                questionTab(question, at: index)
            }
        }
        .padding(Space.xxs)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.field))
    }

    private func questionTab(_ question: AgentQuestion, at index: Int) -> some View {
        let active = index == currentQuestionIndex
        let complete = !answer(for: question).isEmpty
        return Button { showQuestion(at: index) } label: {
            HStack(spacing: Space.sm) {
                if complete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(index + 1)")
                        .font(Typography.micro)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                }
                Text(tabTitle(for: question, at: index))
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(active ? Theme.card : .clear)
                .elevation(active ? .raised : .none))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityLabel("Question \(index + 1): \(tabTitle(for: question, at: index))")
        .accessibilityValue(complete ? "Answered" : "Not answered")
    }

    private func question(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(Typography.micro)
                    .kerning(0.6)
                    .foregroundStyle(Theme.accent)
            }
            Text(question.text)
                .font(Typography.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                optionRow(question: question, option: option)
            }

            // The CLI always offers a way out of the options it was given, so the
            // person is never cornered into an answer that does not fit.
            TextField("Something else…", text: binding(for: question))
                .appTextField(size: 12)
        }
    }

    private func tabTitle(for question: AgentQuestion, at index: Int) -> String {
        question.header.isEmpty ? "Question \(index + 1)" : question.header
    }

    private func showQuestion(at index: Int) {
        withAnimation(reduceMotion ? nil : Motion.reveal) {
            currentQuestionIndex = index
        }
    }

    private func optionRow(question: AgentQuestion, option: AgentQuestion.Option) -> some View {
        let chosen = picked[question.text]?.contains(option.label) ?? false
        return Button {
            choose(option.label, in: question)
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: marker(question: question, chosen: chosen))
                    .font(Typography.detail)
                    .foregroundStyle(chosen ? Theme.accent : Color.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(option.label)
                        .font(Typography.label)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(chosen ? Theme.accent.opacity(0.10) : Theme.card, cornerRadius: Radius.control,
                     border: chosen ? Theme.accent.opacity(0.45) : Theme.border)
            .motion(Motion.control, value: chosen)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
    }

    private func marker(question: AgentQuestion, chosen: Bool) -> String {
        if question.multiSelect { return chosen ? "checkmark.square.fill" : "square" }
        return chosen ? "largecircle.fill.circle" : "circle"
    }

    private func choose(_ label: String, in question: AgentQuestion) {
        typed[question.text] = ""
        if question.multiSelect {
            var current = picked[question.text] ?? []
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
            picked[question.text] = current
        } else {
            picked[question.text] = picked[question.text]?.contains(label) == true ? [] : [label]
        }
    }

    private func binding(for question: AgentQuestion) -> Binding<String> {
        Binding(get: { typed[question.text] ?? "" },
                set: { text in
                    typed[question.text] = text
                    // Typing is an answer of its own, so it clears what was ticked.
                    if !text.isEmpty { picked[question.text] = [] }
                })
    }

    // Every question needs an answer: the tool takes them as one map, and a missing one
    // reads to the agent as a question that was skipped.
    private var isComplete: Bool {
        request.questions.allSatisfy { !answer(for: $0).isEmpty }
    }

    private var isCurrentQuestionComplete: Bool {
        !answer(for: request.questions[currentQuestionIndex]).isEmpty
    }

    private var isLastQuestion: Bool {
        currentQuestionIndex == request.questions.count - 1
    }

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for question in request.questions {
            let answer = answer(for: question)
            if !answer.isEmpty { result[question.text] = answer }
        }
        return result
    }

    // Several picks in a multi-select question go back as one comma-separated string,
    // which is the shape the tool reads them in.
    private func answer(for question: AgentQuestion) -> String {
        let text = (typed[question.text] ?? "").trimmed
        guard text.isEmpty else { return text }
        let chosen = picked[question.text] ?? []
        return question.options
            .filter { chosen.contains($0.label) }
            .map(\.label)
            .joined(separator: ", ")
    }
}

// A button on a tinted card, so its pills are cut from the tint rather than the plain card
// and border used on the page. The label is Theme.card because the tint is read against it,
// which makes it the inverse of the fill in either theme.
private struct CardButton: View {
    let title: String
    var tint: Color = Theme.warningText
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.label)
                .foregroundStyle(prominent ? Theme.card : Color.primary)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .surface(prominent ? tint : tint.opacity(0.18), cornerRadius: Radius.control,
                         border: prominent ? .clear : tint.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}
