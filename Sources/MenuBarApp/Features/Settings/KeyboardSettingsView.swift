import SwiftUI

// Every key the app answers. A key that can be moved shows as a cap to click and press;
// the rest are shown as they are, so the page still says what the whole set is.
struct KeyboardSettingsView: View {
    @Environment(AppSettings.self) private var settings
    // Only one cap listens at a time, so starting another stops the first.
    @State private var recording: AppCommand?
    @State private var problem: (command: AppCommand, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            if settings.keyBindings.hasChanges {
                HStack {
                    Spacer(minLength: 0)
                    InlineLink(title: "Reset all keys", icon: "arrow.uturn.backward") {
                        recording = nil
                        problem = nil
                        settings.keyBindings.resetAll()
                    }
                }
                .transition(.fadeIn)
            }
            ForEach(AppCommand.groups, id: \.title) { group in
                ChoiceBlock(group.title.uppercased()) {
                    SettingsCard {
                        ForEach(Array(group.commands.enumerated()), id: \.element) { index, command in
                            if index > 0 { SettingsRowDivider() }
                            row(command)
                        }
                    }
                }
            }
        }
        .motion(Motion.reveal, value: settings.keyBindings.hasChanges)
        .onChange(of: recording) { _, now in
            if now != problem?.command { problem = nil }
        }
    }

    private func row(_ command: AppCommand) -> some View {
        let info = command.info
        return HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(info.title)
                    .font(Typography.body.weight(.semibold))
                Text(info.detail)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem, problem.command == command {
                    Text(problem.message)
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(Theme.warningText)
                        .transition(.fadeIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(Motion.reveal, value: problem?.message)

            if info.canChange {
                HStack(spacing: Space.sm) {
                    if settings.keyBindings.isChanged(command) {
                        GlyphButton(icon: "arrow.uturn.backward", side: ControlHeight.sm) {
                            if recording == command { recording = nil }
                            settings.keyBindings.reset(command)
                        }
                        .appTooltip("Put back \(info.keys?.label ?? "no key")")
                        .accessibilityLabel("Reset \(info.title) to \(info.keys?.spokenLabel ?? "no key")")
                        .transition(.fadeIn)
                    }
                    KeyRecorder(keys: settings.keyBindings.keys(for: command),
                                isRecording: recordingBinding(command),
                                onRecord: { record($0, for: command) },
                                onClear: {
                                    problem = nil
                                    settings.keyBindings.set(nil, for: command)
                                })
                }
                .motion(Motion.control, value: settings.keyBindings.isChanged(command))
            } else if let label = settings.keyBindings.label(for: command) {
                Text(label)
                    .font(Typography.data.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xxs)
                    .fieldSurface(cornerRadius: Radius.inset)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
    }

    // A key that cannot be used keeps the cap listening, with the reason under the name,
    // so the next try is one press away.
    private func record(_ keys: KeyCombo, for command: AppCommand) {
        if let reason = settings.keyBindings.problem(with: keys, for: command) {
            problem = (command, "\(keys.label): \(reason.message)")
            return
        }
        problem = nil
        settings.keyBindings.set(keys, for: command)
        recording = nil
    }

    private func recordingBinding(_ command: AppCommand) -> Binding<Bool> {
        Binding(get: { recording == command },
                set: { recording = $0 ? command : (recording == command ? nil : recording) })
    }
}
