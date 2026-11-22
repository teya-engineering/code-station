import AppKit
import SwiftUI

// A reading that keeps changing on its own clock, such as a count of seconds while a turn
// runs. Any change inside the window's view tree makes SwiftUI update and lay out the
// whole window, which with a long transcript open costs several milliseconds a time, and
// a few clocks ticking every second add up to a window that feels slow under the pointer.
// So the clock is drawn by a hosting view of its own and redraws only itself.
//
// The window cannot see the reading inside that view, so it keeps room for it with a
// hidden copy of the reading's shape: the same text with every digit turned to a zero.
// Digits are drawn at one width, so the shape only changes when the reading gains a
// digit or a unit, such as at 10s or at 1m, and only then is the window laid out again.
struct TickingReading<Label: View>: View {
    let since: Date
    let reading: (_ since: Date, _ now: Date) -> String
    @ViewBuilder let label: (String) -> Label

    @State private var shape: String?

    var body: some View {
        label(shape ?? Self.shape(of: reading(since, .now)))
            .hidden()
            .overlay(alignment: .leading) {
                OwnHost(content: clock)
            }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text = reading(since, context.date)
            label(text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .onChange(of: Self.shape(of: text), initial: true) { _, new in
                    if shape != new { shape = new }
                }
        }
    }

    static func shape(of text: String) -> String {
        String(text.map { $0.isNumber ? "0" : $0 })
    }
}

private struct OwnHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> OwnHostView { OwnHostView() }

    // The hosting view starts from a blank environment, so it is handed the one the
    // reading would have been drawn with in place.
    func updateNSView(_ view: OwnHostView, context: Context) {
        view.host.rootView = AnyView(content.environment(\.self, context.environment))
    }
}

final class OwnHostView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Without sizing options the inner view never asks the window to make room,
        // which is the whole point of drawing the reading here.
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Clicks and hover belong to whatever the reading sits in, such as a button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Counts up while something runs. The reading has to keep ticking when nothing arrives to
// redraw it, which is the case a live clock exists for. Sidebar type stays a fixed size;
// transcript type follows the size the user picked, which is what `scaled` asks for.
struct ElapsedTime: View {
    let since: Date
    var size: CGFloat = 8.5
    var scaled = false

    @Environment(\.textScale) private var textScale

    var body: some View {
        TickingReading(since: since, reading: { since, now in
            Self.reading(now.timeIntervalSince(since))
        }) { text in
            Text(text)
                .font(.mono(size * (scaled ? textScale : 1)))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    // A clock still going: whole seconds, since the tenths would only flicker.
    static func reading(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    // A span that is over. Most tool calls are done in well under a second, and "0s" would
    // make every one of them read as the same instant, so short spans keep their tenths.
    static func duration(_ seconds: TimeInterval) -> String {
        let span = max(0, seconds)
        guard span >= 10 else { return String(format: "%.1fs", span) }
        return reading(span)
    }
}
