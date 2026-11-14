import SwiftUI

struct ChangesProgressLabel: View {
    let title: String
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.sm) {
            if reduceMotion {
                Image(systemName: "hourglass").frame(width: 11, height: 11).accessibilityHidden(true)
            }
            else {
                BreathingCircle(colour: Theme.accent, restingOpacity: 0.35, fullOpacity: 1)
                    .frame(width: 7, height: 7)
                    .frame(width: 11, height: 11)
            }
            if !compact { Text(title) }
        }
        .font(Typography.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// The frame is present immediately; placeholders appear only if the read takes long
// enough to notice. A cached result never flashes a skeleton.
struct ChangesLoadingPlaceholder: View {
    let title: String
    var rows = 3
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ChangesProgressLabel(title: title)
            ForEach(0..<rows, id: \.self) { index in
                VStack(alignment: .leading, spacing: Space.md) {
                    RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.border)
                        .frame(maxWidth: index.isMultiple(of: 2) ? .infinity : 240).frame(height: 11)
                    RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field).frame(width: 110, height: 8)
                }.accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .motion(Motion.reveal, value: visible)
        .task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            visible = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct ChangesSuccessMark: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Checkmark().trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 15, height: 15)
            .motion(Motion.draw, value: drawn)
            .onAppear { drawn = true }
            .accessibilityHidden(true)
    }

    private struct Checkmark: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.52))
                path.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.height * 0.8))
                path.addLine(to: CGPoint(x: rect.width * 0.9, y: rect.height * 0.2))
            }
        }
    }
}
