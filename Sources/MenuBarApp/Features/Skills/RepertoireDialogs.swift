import SwiftUI
import UniformTypeIdentifiers

struct AddMarketplaceView: View {
    @Environment(DialogPresenter.self) private var dialogs
    let manager: SkillsManager
    @State private var repository = ""
    @State private var preview: (SkillMarketplaceConfiguration, SkillMarketplace)?
    @State private var failure: String?
    // Set when the check stopped at a sign-in and the host has an SSH address to try.
    @State private var sshAddress: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SourcePicker(repositoryURL: $repository,
                         repositoryTitle: "Git repository", repositoryDetail: "",
                         placeholder: "https://github.com/org/marketplace.git",
                         fileTitle: "Local file", fileDetail: "", fileButton: "Choose marketplace file",
                         isLoading: loading || manager.isBusy,
                         loadRepository: checkRepository, chooseFile: chooseFile,
                         showsOneSource: true, repositoryButton: "Check marketplace",
                         repositoryHelp: "Use an HTTPS or SSH Git URL. The repository must contain .claude-plugin/marketplace.json.",
                         localFileHelp: "Choose a marketplace JSON file on this Mac.",
                         repositoryChoice: "Git repository", fileChoice: "Local file",
                         onSourceChange: clearResult)
            if let preview {
                SourceLoaded(title: preview.0.label, detail: "\(preview.1.plugins.count) packages available\n\(preview.0.source)")
                ActionButton(title: loading ? "Adding…" : "Add marketplace", tone: .dark) {
                    loading = true
                    let dialogID = dialogs.current?.id
                    Task {
                        do {
                            try await manager.addPreviewedMarketplace(preview.0, catalogue: preview.1)
                            if dialogs.current?.id == dialogID { dialogs.dismiss() }
                        } catch { failure = error.localizedDescription }
                        loading = false
                    }
                }.disabled(loading || manager.isBusy)
            }
            if let failure { SourceFailure(failure, lineLimit: nil) }
            if let sshAddress {
                InlineLink(title: "Use SSH address", size: 11.5, icon: "key") {
                    useSSH(sshAddress)
                }
                .disabled(loading || manager.isBusy)
                .transition(.fadeIn)
            }
            Text("Adding a marketplace does not install any packages.")
                .scaledText(12).foregroundStyle(.secondary)
        }
        .motion(Motion.reveal, value: sshAddress)
        .onChange(of: repository) { _, _ in clearResult() }
    }

    private func clearResult() {
        preview = nil
        failure = nil
        sshAddress = nil
    }

    private func checkRepository() {
        clearResult()
        loading = true
        Task {
            do {
                let result = try await manager.previewMarketplace(gitRepository: repository)
                try accept(result)
            } catch {
                failure = error.localizedDescription
                sshAddress = (error as? GitSignInRequired)?.sshAddress
            }
            loading = false
        }
    }

    // The field takes the SSH address so the user sees what is being tried, and what
    // gets saved if it works.
    private func useSSH(_ address: String) {
        repository = address
        checkRepository()
    }

    private func chooseFile() {
        guard let url = FilePicker.chooseFile(prompt: "Check marketplace", message: "Choose a marketplace JSON file.", types: [.json]) else { return }
        clearResult()
        do { try accept(SkillsManager.localConfiguration(at: url)) }
        catch { failure = error.localizedDescription }
    }

    private func accept(_ result: (SkillMarketplaceConfiguration, SkillMarketplace)) throws {
        guard !manager.marketplaceConfigurations.contains(where: {
            $0.marketplace == result.0.marketplace || $0.source == result.0.source
        }) else { throw ImportError("This marketplace is already connected. Find it in Marketplaces.") }
        preview = result
    }
}

func uninstallDialog(manager: SkillsManager, plugin: SkillMarketplace.Plugin, host: SkillHost) -> Dialog {
    .impact("Uninstall package?", message: plugin.name, rows: [
        .init(title: "Remove from \(host.title)", detail: "This package will no longer be available to this agent."),
        .init(title: "Other agents and marketplace stay unchanged",
              detail: "You can install this package again at any time.", kept: true)
    ], action: "Uninstall package") {
        Task { await manager.setInstalled(false, plugin: plugin, on: host) }
    }
}
