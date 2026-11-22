import SwiftUI

struct SiteConfigurationJSONView: View {
    @Environment(\.dismiss) private var dismiss
    let defaults: SiteDefaults

    @State private var failure: String?
    @State private var showsWhy = false

    private var data: Data? { try? SiteConfigurationImporter.configurationData(for: defaults) }
    private var text: String { data.map { String(decoding: $0, as: UTF8.self) } ?? "{}\n" }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(name: "Current configuration", icon: "curlybraces") {
                WhyButton(label: "Where this comes from", isOpen: $showsWhy) {
                    Text("This read-only view is generated from the current settings and is safe to export as a reset file.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.pane)
            .headerBand()
            .zIndex(1)

            HStack(spacing: Space.md) {
                StatusCaps(text: "JSON")
                StatusRule()
                StatusCaps(text: "READ ONLY")
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .statusBand(padding: Space.pane)

            VStack(alignment: .leading, spacing: Space.md) {
                ScrollView {
                    Text(text)
                        .font(Typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                }
                .frame(height: 440)
                .fieldSurface(cornerRadius: Radius.card)

                if let failure {
                    Text(failure)
                        .font(Typography.detail)
                        .foregroundStyle(Theme.deletion)
                        .transition(.fadeIn)
                }
            }
            .padding(Space.pane)
            .smoothlyResizes(when: failure)

            SheetFooter(dismiss: closeOrDismiss) {
                HStack(spacing: Space.lg) {
                    CopyButton("Copy JSON", size: Typography.Size.detail) { text }
                    InlineLink(title: "Export…", action: export)
                }
            }
        }
        .frame(width: 700)
        .background(Theme.background)
    }

    // Escape puts the explanation away before it closes the sheet.
    private func closeOrDismiss() {
        if showsWhy {
            showsWhy = false
        } else {
            dismiss()
        }
    }

    private func export() {
        guard let data else {
            failure = "The current configuration could not be encoded."
            return
        }
        guard let url = FilePicker.saveFile(suggestedName: "site-configuration.json",
                                            prompt: "Export",
                                            message: "Export the current Code Station configuration.",
                                            types: [.json]) else { return }
        do {
            try data.write(to: url, options: .atomic)
            failure = nil
        } catch {
            failure = "The configuration could not be exported: \(error.localizedDescription)"
        }
    }
}
