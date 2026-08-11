import SwiftUI

// Segmented choices used in pane headers. Keeping the control shared means project and
// session navigation have the same hit areas, spacing and selected state.
struct HeaderTabToggle<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(label: String, value: Selection)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
        // A header row hands out its width between its children, so without this the
        // control is offered less than its labels need and every one of them wraps onto
        // two lines. It is a fixed set of short words: it should hold its size and let
        // the title beside it give way instead.
        .fixedSize(horizontal: true, vertical: false)
    }

    private func segment(_ option: (label: String, value: Selection)) -> some View {
        let active = selection == option.value
        return Button { selection = option.value } label: {
            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Theme.card : .clear)
                        .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The app's own switch and checkbox. The native toggle styles draw with the system's
// chrome and accent, which reads as a piece of another program next to the rest of
// the app, so everything interactive is drawn here with the shared palette instead.

// A switch trails its label, the way a row of settings expects.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.accentFill : Theme.dotOff)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .padding(2)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }
}

// A checkbox leads its label, the way a tickable line expects.
struct AppCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Theme.accentFill : Theme.card)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(configuration.isOn ? .clear : Theme.border, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}

extension ToggleStyle where Self == AppCheckboxStyle {
    static var appCheckbox: AppCheckboxStyle { AppCheckboxStyle() }
}

