import SwiftUI
import UniformTypeIdentifiers

// Loading a site configuration is offered twice, on the first run and in Settings, and
// both places juggle the same things: the address being typed, the load in flight, what
// came back and what went wrong. Keeping that here means each screen only draws it.
@MainActor
@Observable
final class SiteConfigurationLoader {
    var repositoryURL = ""
    private(set) var isLoading = false
    private(set) var selection: SiteConfigurationSelection?
    // Also set by the screen when installing what was loaded fails, so one banner
    // covers both halves of the job.
    var failure: String?

    var canLoadRepository: Bool { !isLoading && !repositoryURL.isBlank }

    func loadRepository() {
        let repository = repositoryURL.trimmed
        guard !isLoading, !repository.isEmpty else { return }
        isLoading = true
        failure = nil
        selection = nil
        Task {
            do {
                selection = try await SiteConfigurationImporter.load(gitHubRepository: repository)
            } catch {
                failure = error.localizedDescription
            }
            isLoading = false
        }
    }

    func chooseFile(message: String) {
        guard !isLoading,
              let url = FilePicker.chooseFile(prompt: "Load", message: message, types: [.json])
        else { return }
        loadFile(url)
    }

    func loadFile(_ url: URL) {
        guard !isLoading else { return }
        do {
            selection = try SiteConfigurationImporter.load(file: url)
            failure = nil
        } catch {
            selection = nil
            failure = error.localizedDescription
        }
    }

    func clear() {
        repositoryURL = ""
        selection = nil
        failure = nil
    }
}

// Shared files come from a Git repository or a JSON file on this Mac. Onboarding
// reveals one source at a time; the skills marketplace offers both cards together.
struct SourcePicker: View {
    private enum Source { case repository, file }

    @Binding var repositoryURL: String
    let repositoryTitle: String
    let repositoryDetail: String
    let placeholder: String
    let fileTitle: String
    let fileDetail: String
    let fileButton: String
    let isLoading: Bool
    let loadRepository: () -> Void
    let chooseFile: () -> Void
    var showsOneSource = false
    var repositoryButton = "Load settings"
    var repositoryHelp = "A root-level site-defaults.json, teya-defaults.json, or one JSON file. Uses your existing Git access. Personal tokens and passwords stay outside this file."
    var localFileHelp = "Choose a settings file on this Mac."
    var repositoryChoice = "GitHub repository"
    var fileChoice = "JSON file"
    var onSourceChange: () -> Void = {}

    @State private var source = Source.repository
    @State private var showsRepositoryHelp = false

    var body: some View {
        if showsOneSource {
            selectedSource
        } else {
            sourceCards
        }
    }

    private var selectedSource: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                ChoicePill(title: repositoryChoice, selected: source == .repository,
                           enabled: !isLoading) { source = .repository; onSourceChange() }
                    .accessibilityAddTraits(source == .repository ? [.isSelected] : [])
                ChoicePill(title: fileChoice, selected: source == .file,
                           enabled: !isLoading) { source = .file; onSourceChange() }
                    .accessibilityAddTraits(source == .file ? [.isSelected] : [])
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Configuration source")

            if source == .repository {
                Text("Repository URL").font(.system(size: 11, weight: .semibold))
                HStack(spacing: 9) {
                    repositoryField
                    ActionButton(title: isLoading ? "Loading…" : repositoryButton,
                                 tone: .outlined, action: loadRepository)
                        .disabled(isLoading || repositoryURL.isBlank)
                }
                InlineLink(title: showsRepositoryHelp
                           ? "Hide repository details" : "What should the repository contain?",
                           size: 11) { showsRepositoryHelp.toggle() }
                    .accessibilityValue(showsRepositoryHelp ? "Expanded" : "Collapsed")
                if showsRepositoryHelp {
                    Text(repositoryHelp)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 12) {
                    ActionButton(title: fileButton, tone: .outlined, icon: "folder",
                                 action: chooseFile)
                        .disabled(isLoading)
                    Text(localFileHelp)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var repositoryField: some View {
        TextField(placeholder, text: $repositoryURL)
            .textFieldStyle(.plain)
            .font(.mono(11.5))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .fieldSurface()
            .accessibilityLabel("GitHub repository URL")
            .disabled(isLoading)
            .onSubmit {
                guard !isLoading, !repositoryURL.isBlank else { return }
                loadRepository()
            }
    }

    private var sourceCards: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceCard(icon: "arrow.triangle.branch", title: repositoryTitle,
                       detail: repositoryDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    repositoryField
                    ActionButton(title: isLoading ? "Loading…" : "Load repository",
                                 tone: .outlined,
                                 icon: isLoading ? nil : "arrow.down.circle",
                                 action: loadRepository)
                        .disabled(isLoading || repositoryURL.isBlank)
                }
            }

            SourceCard(icon: "doc.badge.plus", title: fileTitle, detail: fileDetail) {
                ActionButton(title: fileButton, tone: .outlined, icon: "folder",
                             action: chooseFile)
                    .disabled(isLoading)
            }
        }
    }
}

private struct SourceCard<Content: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    init(icon: String, title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.serif(16))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .cardSurface(cornerRadius: 11)
    }
}

// What a load came back with. A file that read sits on green with its name and what it
// holds; one that did not sits on red with the reason.
struct SourceLoaded: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.addition)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sourceResult(Theme.addition)
    }
}

struct SourceFailure: View {
    let message: String
    let lineLimit: Int?

    init(_ message: String, lineLimit: Int? = 5) {
        self.message = message
        self.lineLimit = lineLimit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(lineLimit)
        }
        .sourceResult(Theme.deletion)
    }
}

extension View {
    // The tinted card a load result sits on, in the colour that says how it went.
    func sourceResult(_ tint: Color) -> some View {
        padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(tint.opacity(0.08), cornerRadius: 9, border: tint.opacity(0.28))
    }
}
