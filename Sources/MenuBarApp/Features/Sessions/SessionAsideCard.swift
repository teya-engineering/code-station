import SwiftUI

// The answer to a /btw question, above the composer. It sits with the rows about the line
// being written rather than in the transcript, because it is not part of the conversation
// and is put away once read.
struct SessionAsideCard: View {
    let aside: Aside
    let projectPath: String
    let textScale: CGFloat
    let dismiss: () -> Void

    // Past this the answer scrolls, so a long one cannot push the composer off the pane.
    private let maxAnswerHeight: CGFloat = 240
    @State private var answerHeight: CGFloat = 0
    // The answer is drawn as several text views, one per block, so it gets a selection
    // of its own that runs across them, the way the transcript's does.
    @State private var selection = TranscriptSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            heading
            Text(aside.question)
                .font(Typography.detail.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            content
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.md)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.card, border: Theme.border)
        .motion(Motion.reveal, value: aside.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side question: \(aside.question)")
    }

    private var heading: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "bubble.left")
                .font(Typography.micro)
            Text("BY THE WAY")
                .font(Typography.caption.weight(.semibold))
                .kerning(1.2)
            Text("· NOT ADDED TO THE CONVERSATION")
                .font(Typography.caption)
                .kerning(1.2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: Space.md)
            if case .answered(let text) = aside.state {
                CopyButton { text }
                    .transition(.fadeIn)
            }
            GlyphButton(icon: aside.isAnswering ? "stop.fill" : "xmark", side: ControlHeight.xs,
                        action: dismiss)
                .contentTransition(.symbolEffect(.replace))
                .appTooltip(aside.isAnswering ? "Stop and put this away" : "Put this away")
                .accessibilityLabel(aside.isAnswering ? "Stop the side question" : "Close the side question")
        }
        .foregroundStyle(Theme.accent)
    }

    @ViewBuilder private var content: some View {
        switch aside.state {
        case .answering(let activity):
            HStack(spacing: Space.sm) {
                LoopSpinner(size: 10)
                Text(activity)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(aside.agent.title) is answering. \(activity)")
        case .answered(let text):
            ScrollView {
                MarkdownProse(text: text, projectPath: projectPath, textScale: textScale) { segment in
                    MarkdownCodeBlock(segment: segment).equatable()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.transcriptSelection, selection)
                .background(TranscriptSelectionClearing(selection: selection))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(answerHeight, maxAnswerHeight))
            .transition(.fadeIn)
        case .failed(let message):
            Text("The side question could not be answered. \(message)")
                .frame(maxWidth: .infinity, alignment: .leading)
                .warningCard()
        }
    }
}
