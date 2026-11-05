import AppKit
import SwiftUI

struct CursorEffectsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Namespace private var scheduleThumb

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cursor effects")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A little extra life around the pointer.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(CursorEffect.allCases) { choice($0) }
                }
            }
            .padding(14)

            SettingsRowDivider()
            schedule.padding(14)
        }
        .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .onChange(of: settings.cursorEffects.effect) { _, effect in
            announce("\(effect.title) selected. Changes saved.")
        }
        .onChange(of: settings.cursorEffects.schedule) { _, schedule in
            announce("Show cursor effects: \(schedule.title). Changes saved.")
        }
    }

    private var schedule: some View {
        let off = settings.cursorEffects.effect == .none
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show")
                    .font(.system(size: 13, weight: .semibold))
                Text(off ? "Pick an effect first." : settings.cursorEffects.schedule.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(CursorEffectSchedule.allCases) { choice in
                    let selected = settings.cursorEffects.schedule == choice
                    ChoicePill(title: choice.title, selected: selected, enabled: !off, thumb: scheduleThumb) {
                        settings.cursorEffects.schedule = choice
                    }
                    .accessibilityLabel("Show cursor effects: \(choice.title)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
        .motion(Motion.control, value: settings.cursorEffects.schedule)
        .motion(Motion.control, value: off)
    }

    private func choice(_ effect: CursorEffect) -> some View {
        CursorEffectChoice(effect: effect, selected: settings.cursorEffects.effect == effect) {
            settings.cursorEffects.effect = effect
        }
    }

    private func announce(_ text: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

private struct CursorEffectChoice: View {
    let effect: CursorEffect
    let selected: Bool
    let choose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                CursorEffectThumbnail(effect: effect).frame(width: 30, height: 42).accessibilityHidden(true)
                copy
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .surface(selected ? Theme.accent.opacity(0.08) : Theme.field, cornerRadius: 9,
                     border: selected || focused ? Theme.accent : Theme.settingsBorder)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverLift(amount: reduceMotion ? 1 : Motion.lift).focused($focused)
        .motion(Motion.control, value: selected)
        .accessibilityLabel("Cursor effect: \(effect.title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(effect.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(effect.title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10)).foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            Text(effect.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CursorEffectThumbnail: View {
    let effect: CursorEffect

    var body: some View {
        ZStack {
            Color(nsColor: Theme.canvasDarkNSColor)
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.56, y: size.height * 0.48)
                switch effect {
                case .none: break
                case .ember:
                    for index in 0..<32 {
                        let t = Double(index) / 32
                        let x = 5 + t * (size.width - 10)
                        let y = size.height * 0.55 - sin(t * .pi) * 17 + sin(Double(index) * 7) * 9
                        var spark = Path()
                        spark.move(to: CGPoint(x: x, y: y))
                        spark.addLine(to: CGPoint(x: x - 2, y: y + 3))
                        context.stroke(spark, with: .color(.orange.opacity(0.3 + t * 0.7)), lineWidth: 1)
                    }
                case .aurora:
                    var ribbon = Path()
                    ribbon.move(to: CGPoint(x: 3, y: size.height * 0.65))
                    ribbon.addCurve(to: CGPoint(x: size.width - 6, y: size.height * 0.4),
                                    control1: CGPoint(x: size.width * 0.45, y: size.height * 0.7),
                                    control2: CGPoint(x: size.width * 0.65, y: size.height * 0.1))
                    for width in [9.0, 4, 1.5] {
                        context.stroke(ribbon, with: .linearGradient(Gradient(colors: [.teal.opacity(0.2), .purple]),
                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: width)
                    }
                case .orbit:
                    for index in 0..<2 {
                        let ellipse = Path(ellipseIn: CGRect(x: -20, y: -12, width: 40, height: 24))
                            .applying(CGAffineTransform(rotationAngle: index == 0 ? -0.6 : 1.1)
                                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                        context.stroke(ellipse, with: .color(.cyan.opacity(0.45)), lineWidth: 0.7)
                    }
                    for offset in [-1.0, 1] {
                        context.fill(Path(ellipseIn: CGRect(x: center.x + offset * 16 - 1.5,
                            y: center.y + offset * 8 - 1.5, width: 3, height: 3)), with: .color(.cyan))
                    }
                case .ripple:
                    let water = Color(red: 0.45, green: 0.78, blue: 0.64)
                    for (index, radius) in [5.0, 10, 15, 20].enumerated() {
                        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                          width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(water.opacity(0.85 - Double(index) * 0.2)), lineWidth: 0.8)
                    }
                case .prism:
                    for index in 0..<4 {
                        let t = Double(index) / 3
                        let tip = CGPoint(x: center.x - 2 - (1 - t) * 13, y: center.y + 4 + (1 - t) * 13)
                        let side = 5 + t * 5
                        var facet = Path()
                        facet.move(to: tip)
                        facet.addLine(to: CGPoint(x: tip.x - side * 0.4, y: tip.y + side))
                        facet.addLine(to: CGPoint(x: tip.x + side * 0.9, y: tip.y + side * 0.45))
                        facet.closeSubpath()
                        let hue = Color(hue: 0.55 + t * 0.27, saturation: 0.5, brightness: 0.95)
                        context.fill(facet, with: .color(hue.opacity(0.25 + t * 0.35)))
                        context.stroke(facet, with: .color(hue.opacity(0.5 + t * 0.4)), lineWidth: 0.6)
                    }
                }
            }
            GeometryReader { geometry in
                Image(systemName: "cursorarrow").font(.system(size: 14))
                    .foregroundStyle(.white)
                    .position(x: geometry.size.width * 0.56, y: geometry.size.height * 0.48)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
