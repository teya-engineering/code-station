import AppKit
import SwiftUI
import CodeStationCore

struct TurnHandoffArrival: Equatable {
    private(set) var ending: Date?

    mutating func observe(_ latest: TurnEnding?, visible: Bool, now: Date = Date()) -> Bool {
        guard let latest, latest.ended != ending else { return false }
        ending = latest.ended
        return visible && latest.isFresh(now: now)
    }
}

struct TurnSeal: View {
    let ending: TurnEnding
    let receipt: TurnReceipt
    var reviewed = false
    var arriving = false
    var focusReview = false
    var review: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var reviewFocused: Bool
    @State private var arrival: CGFloat = 1
    @State private var played = false

    var body: some View {
        Tweened(progress: arrival) { progress in
            let look = TurnSealArrival(progress: reduceMotion ? 1 : progress)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metadata(look)
                    reviewButton
                }
                VStack(alignment: .leading, spacing: 9) {
                    FlowRow(spacing: 9) { metadata(look) }
                    if receipt.hasChanges, review != nil {
                        HStack { Spacer(minLength: 0); reviewButton }
                    }
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.3), lineWidth: 1))
            .opacity(look.opacity)
            .offset(y: look.offset)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn handoff")
        .task(id: arriving) {
            if focusReview { reviewFocused = true }
            guard arriving, !played else { return }
            played = true
            guard !reduceMotion else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { arrival = 0 }
            await Task.yield()
            guard !Task.isCancelled else { arrival = 1; return }
            withAnimation(.linear(duration: TurnSealArrival.duration)) { arrival = 1 }
        }
        .onChange(of: focusReview) { _, focused in reviewFocused = focused }
    }

    private var tint: Color { ending.outcome == .finished ? Theme.addition : Theme.attentionText }

    @ViewBuilder private func metadata(_ look: TurnSealArrival) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                if ending.outcome == .finished {
                    TurnSealCheck().trim(from: 0, to: look.check)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round,
                                                        lineJoin: .round))
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: ending.outcome == .stopped ? "pause.fill" : "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 22, height: 22)
            .scaleEffect(ending.outcome == .finished ? look.markScale : 1)
            .accessibilityHidden(true)
            Text(ending.outcome == .finished ? (reviewed ? "Reviewed" : "Finished") : "Stopped")
                .font(.system(size: 11, weight: .semibold))
            Text("\(ending.outcome == .finished ? "in" : "after") \(TurnReceipt.clock(ending.duration))")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(height: 30)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((reviewed ? "Changes reviewed. " : "") + receipt.spokenSummary(ending))

        HStack(spacing: 8) {
            if receipt.hasChanges {
                Text(receipt.filePhrase)
                HStack(spacing: 5) {
                    Text("+\(receipt.added)").foregroundStyle(Theme.addition)
                    Text("\u{2212}\(receipt.removed)").foregroundStyle(Theme.deletion)
                }
                .monospacedDigit()
            } else {
                Text("No files changed").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1, height: 14) }
        .frame(height: 30)
        .fixedSize()
        .accessibilityHidden(receipt.hasChanges)
    }

    @ViewBuilder private var reviewButton: some View {
        if receipt.hasChanges, let review {
            ActionButton(title: reviewed ? "View changes" : "Review changes", tone: .green,
                         height: 30, size: 10, trailingIcon: "arrow.right", action: review)
                .focusable()
                .focused($reviewFocused)
                .focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 7.5)
                    .stroke(reviewFocused ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                .onKeyPress(keys: [.space, .return]) { _ in review(); return .handled }
                .accessibilityHint("Opens the uncommitted changes, including edits made before this turn, or the commits this turn made when nothing is left uncommitted")
        }
    }
}

struct TurnReviewFooter: View {
    let back: () -> Void
    let markReviewed: () -> Void
    @FocusState private var focused: Int?

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Back to conversation", tone: .outlined,
                         height: 30, size: 11, icon: "arrow.left", action: back)
                .focusable()
                .focused($focused, equals: 0)
                .focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 7.5)
                    .stroke(focused == 0 ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                .onKeyPress(keys: [.space, .return]) { _ in back(); return .handled }
            Spacer(minLength: 0)
            ActionButton(title: "Mark reviewed", tone: .green, height: 30, size: 11,
                         icon: "checkmark", action: markReviewed)
                .focusable()
                .focused($focused, equals: 1)
                .focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 7.5)
                    .stroke(focused == 1 ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                .onKeyPress(keys: [.space, .return]) { _ in markReviewed(); return .handled }
                .accessibilityHint("Marks this turn reviewed without committing changes")
        }
        .padding(12)
        .background(Theme.card)
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
        .onAppear { focused = 0 }
    }
}

// A single finite timeline keeps the row, mark, and stroke settled by the same deadline.
struct TurnSealArrival {
    static let duration = 0.38
    let progress: CGFloat

    private func eased(after delay: Double, duration: Double,
                       start: UnitPoint, end: UnitPoint) -> CGFloat {
        let elapsed = Double(progress) * Self.duration
        let fraction = min(1, max(0, (elapsed - delay) / duration))
        return UnitCurve.bezier(startControlPoint: start, endControlPoint: end).value(at: fraction)
    }

    var opacity: CGFloat {
        eased(after: 0, duration: 0.38, start: UnitPoint(x: 0.16, y: 1), end: UnitPoint(x: 0.3, y: 1))
    }
    var offset: CGFloat { 6 * (1 - opacity) }
    var markScale: CGFloat {
        0.8 + 0.2 * eased(after: 0.07, duration: 0.28,
                          start: UnitPoint(x: 0.2, y: 0.8), end: UnitPoint(x: 0.2, y: 1))
    }
    var check: CGFloat {
        eased(after: 0.14, duration: 0.21, start: .zero, end: UnitPoint(x: 0.58, y: 1))
    }
}

private struct TurnSealCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.15, y: rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.width * 0.9, y: rect.height * 0.2))
        return path
    }
}
