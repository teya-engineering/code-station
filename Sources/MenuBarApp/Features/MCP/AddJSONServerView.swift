import SwiftUI

struct AddJSONServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var environment = ""
    @State private var error: String?
    // What the editor last told about its text: where the servers are, and whether it is
    // laid out or could be. Kept here rather than read again on every render: the editor
    // reads it once per change already.
    @State private var status = JSONPayloadEditor.Status()
    // Bumped by the footer's Paste, which the editor carries out as a Cmd+V over the box.
    @State private var pasteRequest = 0
    // Bumped by Format, which lays out text typed by hand. Shown only while the text
    // reads as JSON and is not laid out yet, so it never does nothing.
    @State private var formatRequest = 0


    // When the paste wraps its servers, as setup guides do in "mcpServers", says which
    // servers will be added and that the greyed-out wrapper around them is left out. When
    // an entry is not a server, says so whether wrapped or not: the import refuses the
    // whole paste over it, so the note does not promise the others.
    private var wrapperNote: String? {
        guard let servers = status.servers else { return nil }
        if servers.unnamed { return JSONPayload.unnamedServerMessage }
        let wrapper = "\"" + servers.wrapper.joined(separator: " › ") + "\""
        let place = servers.wrapper.isEmpty ? "" : " in \(wrapper)"
        switch servers.notServers.count {
        case 0: break
        case 1: return "\"\(servers.notServers[0])\"\(place) needs a \"command\" or a \"url\", so nothing can be added yet."
        default: return "\(servers.notServers.count) entries\(place) need a \"command\" or a \"url\", so nothing can be added yet."
        }
        guard !servers.wrapper.isEmpty else { return nil }
        let names = servers.names
        // Text that does not parse yet is only a guess at what will be added, and Add
        // would refuse it, so the note promises nothing until it does.
        let adds = servers.parsed ? "Adds" : "Will add"
        let until = servers.parsed ? "" : " once the JSON reads"
        switch names.count {
        case 0: return "No servers inside \(wrapper) yet."
        case 1: return "\(adds) \(names[0]) from \(wrapper)\(until). The greyed-out part is left out."
        case 2: return "\(adds) \(names[0]) and \(names[1]) from \(wrapper)\(until). The greyed-out part is left out."
        default: return "\(adds) \(names.count) servers from \(wrapper)\(until). The greyed-out part is left out."
        }
    }

    private static let placeholder = """
    {
      "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
        "env": {}
      }
    }
    """

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Add MCP server").font(Typography.display)
                Text("Paste a server as JSON, for stdio or remote (url) servers. Accepts a bare \"name\": { … } map, or the setup snippet for Claude, Cursor or VS Code.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.md) {
                    SectionLabel("ENVIRONMENT")
                    ServerEnvironmentPills(tag: $environment)
                    Text("Which diagnoses offer these servers. JSON that names its own \"environment\" keeps it.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("JSON")
                    Spacer(minLength: 0)
                    // Format and the mark it leaves share a place and a glyph, so a click
                    // reads as the link settling into what it did.
                    if status.formatted {
                        Label("Formatted", systemImage: "text.alignleft")
                            .font(Typography.detail.weight(.medium))
                            .foregroundStyle(.secondary)
                            .transition(.fadeIn)
                            .accessibilityLabel("JSON formatted")
                    } else if status.formattable {
                        InlineLink(title: "Format", size: Typography.Size.detail, icon: "text.alignleft") {
                            formatRequest += 1
                        }
                        .transition(.fadeIn)
                        .accessibilityLabel("Format JSON")
                    }
                }
                .motion(Motion.pop, value: status.formatted)
                .motion(Motion.reveal, value: status.formattable)
                VStack(alignment: .leading, spacing: Space.md) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(Self.placeholder)
                                .font(Typography.code)
                                .foregroundStyle(.tertiary)
                                .padding(Space.md)
                                .allowsHitTesting(false)
                        }
                        JSONPayloadEditor(text: $text, pasteRequest: pasteRequest,
                                          formatRequest: formatRequest,
                                          onStatus: { status = $0 },
                                          onNothingToPaste: {
                                              error = "The clipboard holds no text to paste."
                                          })
                    }
                    .frame(height: 260)
                    .fieldSurface(cornerRadius: Radius.card)

                    if let wrapperNote {
                        Label(wrapperNote, systemImage: "scope")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            // A plain fade either way, so it holds under Reduce Motion too.
                            // Leaving is quicker than arriving.
                            .transition(.asymmetric(insertion: .opacity,
                                                    removal: .opacity.animation(Motion.leave)))
                    }
                }
                .motion(Motion.reveal, value: wrapperNote)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typography.detail)
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.animation(Motion.leave)))
                }
            }
            .motion(Motion.reveal, value: error)
            .padding(Space.xxxl)

            SheetFooter(primary: SheetAction(title: "Add", enabled: !text.isBlank,
                                             shortcut: .defaultAction, action: add),
                        dismiss: { dismiss() }) {
                InlineLink(title: "Paste", size: Typography.Size.body) { pasteRequest += 1 }
            }
        }
        .frame(width: 540)
        .background(Theme.background)
        .onChange(of: text) {
            // Whatever went wrong was about the text before this change.
            error = nil
        }
    }

    private func add() {
        do {
            try store.importJSON(text, environment: environment)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
