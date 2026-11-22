import SwiftUI

// One reviewer's lane on a plan, an answer or a design: what it is reading and for how
// long while it works, and what it came to once it stops. A running lane names the model it runs on; a finished one drops
// that to save room and keeps it in the tooltip.
struct ReviewLane: View {
    enum State: Equatable {
        case running
        case finished(String)
        case failed(String)
    }

    let reviewer: SecondOpinion.Reviewer
    let started: Date
    var ended: Date?
    var activity = ""
    let state: State
    let stop: () -> Void
    let retry: () -> Void
    var dismiss: (() -> Void)?
    // A lane in a narrow column takes the column's width and wraps a failure, where a lane in
    // a row keeps to one line at its own width.
    var fillsWidth = false

    init(reviewer: SecondOpinion.Reviewer, started: Date, ended: Date? = nil, activity: String,
         state: State, fillsWidth: Bool = false,
         stop: @escaping () -> Void, retry: @escaping () -> Void, dismiss: (() -> Void)? = nil) {
        self.reviewer = reviewer
        self.started = started
        self.ended = ended
        self.activity = activity
        self.state = state
        self.fillsWidth = fillsWidth
        self.stop = stop
        self.retry = retry
        self.dismiss = dismiss
    }

    private var name: String { reviewer.label() }

    var body: some View {
        Group {
            if fillsWidth, case .failed(let message) = state {
                failure(message)
            } else {
                line
                    .padding(.leading, Space.md).padding(.trailing, Space.xs)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30, maxHeight: 30, alignment: .leading)
            }
        }
        .font(Typography.detail)
        .surface(fill, cornerRadius: Radius.control, border: border)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .appTooltip(name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var line: some View {
        HStack(spacing: Space.sm) {
            switch state {
            case .running:
                LoopSpinner(size: 10)
                Text(reviewer.agent.title).font(Typography.label).fixedSize()
                if let seat = reviewer.seatLabel {
                    Text(seat)
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.sunken))
                        .fixedSize()
                }
                Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: fillsWidth ? .infinity : 170, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(from: started, to: context.date)).font(Typography.data).foregroundStyle(.tertiary)
                }
                GlyphButton(icon: "stop.fill", side: ControlHeight.xs, action: stop)
                    .appTooltip("Stop")
                    .accessibilityLabel("Stop \(name)")
            case .finished(let outcome):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.dotOn)
                Text(reviewer.agent.title).font(Typography.label).fixedSize()
                Text(outcome + " · " + Self.clock(from: started, to: ended ?? Date()))
                    .foregroundStyle(.secondary).lineLimit(1)
                if fillsWidth { Spacer(minLength: 0) }
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warningText)
                Text("\(reviewer.agent.title) could not finish").font(Typography.label)
                    .foregroundStyle(Theme.warningText).lineLimit(1)
                Text(message).foregroundStyle(Theme.warningText.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .appTooltip(message)
                InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(reviewer.agent.title) could not finish").font(Typography.label)
                Spacer(minLength: 0)
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            }
            Text(message).foregroundStyle(Theme.warningText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
        }
        .foregroundStyle(Theme.warningText)
        .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fill: Color {
        switch state {
        case .running: Theme.field
        case .finished: Theme.dotOn.opacity(0.08)
        case .failed: Theme.warningBackground
        }
    }

    private var border: Color {
        switch state {
        case .failed: Theme.warningText.opacity(0.3)
        default: Theme.border
        }
    }

    private var spoken: String {
        switch state {
        case .running: "\(name) is reviewing. \(activity)"
        case .finished(let outcome): "\(name) finished. \(outcome)"
        case .failed(let message): "\(name) could not finish. \(message)"
        }
    }

    static func clock(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

// The way into a second opinion on a plan. It leads with the usual
// reviewers' tiles, so the lineup the dialog will start from is the button's mark.
struct SecondOpinionButton: View {
    let usual: [AgentKind]
    let action: () -> Void

    @Environment(\.secondOpinionAnchor) private var anchor
    @State private var hovering = false
    @State private var deals = 0
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            deals += 1
            anchor(frame)
            action()
        } label: {
            HStack(spacing: Space.sm) {
                if !usual.isEmpty {
                    LineupTiles(agents: usual, fanned: hovering, deals: deals)
                        .motion(Motion.hover, value: hovering)
                }
                Text("Second opinion").font(Typography.label)
            }
            .padding(.horizontal, Space.md).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(hovering ? Theme.field : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .anchorsSecondOpinion { frame = $0 }
        .accessibilityLabel("Ask for a second opinion")
    }
}

// Three steps for how far a reviewer stands from the author, always beside words that
// say the same. A seat whose model is chosen for it shows dashed steps.
struct IndependenceMeter: View {
    let independence: SecondOpinion.Independence

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(0..<3, id: \.self) { step in
                if independence == .unknown {
                    Capsule().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 10, height: 4)
                } else {
                    Capsule().fill(step < independence.steps ? tint : Theme.border)
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch independence {
        case .differentMaker: Theme.dotOn
        case .otherModel: Theme.dotOn.opacity(0.65)
        case .sameModel, .unknown: Theme.attention
        }
    }
}
