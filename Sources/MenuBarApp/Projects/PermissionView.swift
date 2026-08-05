import SwiftUI

// The agent waiting on the person, at the foot of the transcript. A tool asking for
// permission and a question with options are the same thing on the wire, but not to read:
// one is a yes or no about something about to happen, the other is a choice being asked
// for, so each gets its own card.
struct PermissionCard: View {
    let request: PermissionRequest
    let onAnswer: (PermissionAnswer) -> Void

    var body: some View {
        if request.isQuestion {
            QuestionCard(request: request, onAnswer: onAnswer)
        } else {
            approval
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                Text("\(request.title) needs permission")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ChatColor.warningText)

            // The description explains the intent, the subject is what will actually run.
            // Both are worth having, but only one of them can be checked.
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !request.subject.isEmpty {
                Text(request.subject)
                    .font(.mono(12))
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            }

            HStack(spacing: 8) {
                CardButton(title: "Allow", prominent: true) { onAnswer(.allowOnce) }
                if let always = request.alwaysTitle {
                    CardButton(title: always) { onAnswer(.allowAlways) }
                }
                Spacer(minLength: 0)
                CardButton(title: "Deny") { onAnswer(.deny) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatColor.warningBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatColor.warningText.opacity(0.25)))
    }
}

private struct QuestionCard: View {
    let request: PermissionRequest
    let onAnswer: (PermissionAnswer) -> Void

    // Question text to what is picked so far. Multi-select keeps a set, a single choice
    // keeps the one label, and typed text replaces both.
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty {
                        Text(question.header.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(question.text)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(question.options) { option in
                        optionRow(question: question, option: option)
                    }

                    // The CLI always offers a way out of the options it was given, so the
                    // person is never cornered into an answer that does not fit.
                    TextField("Something else…", text: binding(for: question))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                }
            }

            HStack(spacing: 8) {
                CardButton(title: "Send", prominent: true) { onAnswer(.answers(answers)) }
                    .disabled(!isComplete)
                    .opacity(isComplete ? 1 : 0.45)
                Spacer(minLength: 0)
                CardButton(title: "Skip") { onAnswer(.deny) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.25)))
    }

    private func optionRow(question: AgentQuestion, option: AgentQuestion.Option) -> some View {
        let chosen = picked[question.text]?.contains(option.label) ?? false
        return Button {
            choose(option.label, in: question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: marker(question: question, chosen: chosen))
                    .font(.system(size: 12))
                    .foregroundStyle(chosen ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Theme.accent.opacity(0.10) : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(chosen ? Theme.accent.opacity(0.45) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for question in request.questions where !answer(for: question).isEmpty {
            result[question.text] = answer(for: question)
        }
        return result
    }

    // Several picks in a multi-select question go back as one comma-separated string,
    // which is the shape the tool reads them in.
    private func answer(for question: AgentQuestion) -> String {
        let text = (typed[question.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        let chosen = picked[question.text] ?? []
        return question.options
            .filter { chosen.contains($0.label) }
            .map(\.label)
            .joined(separator: ", ")
    }
}

private struct CardButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? Color.black.opacity(0.88) : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(prominent ? .clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
