import SwiftUI
import CodeStationCore

struct BotPhotoCropView: View {
    @Environment(DialogPresenter.self) private var dialogs
    @Bindable var crop: BotPhotoCrop
    let use: (Data) -> Void
    @FocusState private var focused: Control?
    @State private var dragStart: CGPoint?
    @State private var error: String?

    private enum Control: Int, CaseIterable { case zoom, across, down, cancel, use }
    private let side: CGFloat = 210

    var body: some View {
        VStack(spacing: 12) {
            stage
            Text("Drag to move your picture, or use the controls below.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            BotCropSlider(title: "Zoom", value: $crop.zoom, range: 1...2.5, step: 0.05, focused: focused == .zoom)
                .focused($focused, equals: .zoom)
            BotCropSlider(title: "Across", value: $crop.across, range: -1...1, step: 0.05, focused: focused == .across)
                .focused($focused, equals: .across)
            BotCropSlider(title: "Up / down", value: $crop.down, range: -1...1, step: 0.05, focused: focused == .down)
                .focused($focused, equals: .down)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warningText)
            }
            HStack {
                Spacer()
                ActionButton(title: "Cancel", tone: .outlined, keyboardShortcut: .cancelAction) { dialogs.dismiss() }
                    .focused($focused, equals: .cancel)
                    .overlay(Capsule().stroke(focused == .cancel ? Theme.accent : .clear, lineWidth: 2))
                ActionButton(title: "Use picture", tone: .green, keyboardShortcut: .defaultAction) { apply() }
                    .focused($focused, equals: .use)
                    .overlay(Capsule().stroke(focused == .use ? Theme.accent : .clear, lineWidth: 2))
            }
            .padding(.top, 4)
        }
        .onKeyPress(keys: [.tab]) { press in
            let controls = Control.allCases
            let index = focused?.rawValue ?? Control.cancel.rawValue
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focused = controls[(index + step + controls.count) % controls.count]
            return .handled
        }
        .onAppear { focused = .cancel }
    }

    private var stage: some View {
        let scale = max(side / CGFloat(crop.image.width), side / CGFloat(crop.image.height)) * crop.zoom
        let width = CGFloat(crop.image.width) * scale
        let height = CGFloat(crop.image.height) * scale
        return Image(decorative: crop.image, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .offset(x: (width - side) / 2 * crop.across, y: (height - side) / 2 * crop.down)
            .frame(width: side, height: side)
            .clipped()
            .overlay(Circle().stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5])))
            .overlay(Rectangle().stroke(Theme.border))
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { drag in
                if dragStart == nil { dragStart = CGPoint(x: crop.across, y: crop.down) }
                guard let start = dragStart else { return }
                if width > side {
                    crop.across = min(1, max(-1, start.x + drag.translation.width / ((width - side) / 2)))
                }
                if height > side {
                    crop.down = min(1, max(-1, start.y + drag.translation.height / ((height - side) / 2)))
                }
            }.onEnded { _ in dragStart = nil })
            .accessibilityLabel("Crop preview. Use Zoom, Across, and Up / down to adjust the picture.")
    }

    private func apply() {
        do {
            let data = try crop.pngData()
            dialogs.dismiss()
            use(data)
        } catch {
            self.error = "The picture couldn't be cropped. Try a different crop or choose another file."
        }
    }
}

private struct BotCropSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let focused: Bool

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11.5)).frame(width: 60, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field).frame(height: 6)
                    Capsule().fill(Theme.accent).frame(width: max(0, geometry.size.width * fraction), height: 6)
                    Circle().fill(Theme.card).overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, geometry.size.width - 14) * fraction)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = min(1, max(0, drag.location.x / max(1, geometry.size.width)))
                    value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 28)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.mono(10)).frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            adjust(direction == .right || direction == .up ? step : -step)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(step)
            case .decrement: adjust(-step)
            @unknown default: break
            }
        }
    }

    private func adjust(_ amount: Double) { value = min(range.upperBound, max(range.lowerBound, value + amount)) }
}
