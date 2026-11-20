import SwiftUI

// The keys the command menu answers while it is open. Each one is only ever borrowed:
// with no menu on screen the answer is false and the key keeps the meaning it has
// everywhere else, so return still sends and the arrows still walk the prompt history.
enum CommandKey {
    case up
    case down
    // Tab.
    case complete
    // Return, which also sends, so the menu takes it less often than tab.
    case submit
    case cancel
}

// The commands matching what is being typed, listed above the composer. It sits there
// rather than floating over the transcript because the list is about the line being
// written, and the composer is what grows and shrinks around it.
struct SlashCommandMenu: View {
    let agent: AgentKind
    let commands: [AgentCommand]
    // Matches that only run as the first word of a prompt, for a word further in. They
    // are listed under a rule, greyed, so it is clear why they will not run there, and
    // can be neither picked nor reached with the arrows.
    var startOnly: [AgentCommand] = []
    let selected: Int
    let choose: (AgentCommand) -> Void
    let highlight: (Int) -> Void

    // Past this the list scrolls. A menu taller than this starts to cover the answer the
    // command is being typed about. The height allowed per row is a little more than a
    // row takes, so the top of the next one shows and the list reads as having more.
    private static let visibleRows = 5
    private let rowHeight = ControlHeight.lg + Space.xs

    var body: some View {
        Group {
            // A list that fits is laid out as it is. Only a longer one is put in a
            // scroller, which is also what keeps the keyboard walking it in view.
            if commands.count + startOnly.count > Self.visibleRows {
                ScrollViewReader { proxy in
                    ScrollView {
                        rows
                    }
                    .frame(height: CGFloat(Self.visibleRows) * rowHeight + Space.md)
                    .onChange(of: selected) { _, index in
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            } else {
                rows
            }
        }
        .surface(Theme.card, cornerRadius: Radius.card, border: Theme.border)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands matching what you typed")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                row(command, index: index)
                    .id(index)
            }
            if !startOnly.isEmpty {
                if !commands.isEmpty {
                    Divider()
                        .overlay(Theme.hairline)
                        .padding(.vertical, Space.xs)
                        .padding(.horizontal, Space.md)
                        .accessibilityHidden(true)
                }
                ForEach(startOnly) { command in
                    startOnlyRow(command)
                }
            }
        }
        .padding(Space.xs)
    }

    private func startOnlyRow(_ command: AgentCommand) -> some View {
        HStack(spacing: Space.md) {
            Text(command.typed)
                .font(Typography.code.weight(.semibold))
                .fixedSize()
            Text(Self.startOnlyNote)
                .font(Typography.detail)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label(for: command.scope))
                .capsText()
                .fixedSize()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.lg)
        .accessibilityRepresentation {
            Button("\(command.typed). \(Self.startOnlyNote)") {}
                .disabled(true)
        }
    }

    static let startOnlyNote = "Only works at the start of a prompt"

    private func row(_ command: AgentCommand, index: Int) -> some View {
        let isSelected = index == selected
        return Button { choose(command) } label: {
            HStack(spacing: Space.md) {
                Text(command.typed)
                    .font(Typography.code.weight(.semibold))
                    .foregroundStyle(isSelected ? Theme.accent : .primary)
                    .fixedSize()
                Text(command.summary)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(label(for: command.scope))
                    .capsText()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.lg)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(isSelected ? Theme.accent.opacity(0.1) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(command.typed). \(command.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onPointerHover { hovering in
            if hovering { highlight(index) }
        }
    }

    // Who answers the command, which is the part that decides whether it works at all
    // when a session is moved from one agent to another.
    private func label(for scope: AgentCommand.Scope) -> String {
        switch scope {
        case .app: "CODE STATION"
        case .builtIn: agent.title.uppercased()
        case .user: "YOURS"
        case .project: "PROJECT"
        case .plugin: "PLUGIN"
        }
    }
}
