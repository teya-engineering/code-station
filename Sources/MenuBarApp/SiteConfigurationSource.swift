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

// Two cards offering the two places a shared file can come from: a Git repository to
// clone, or a JSON file already on this Mac. The wizard and the skills marketplace both
// ask the same question, so they ask it with the same cards.
struct SourcePicker: View {
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceCard(icon: "arrow.triangle.branch", title: repositoryTitle,
                       detail: repositoryDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(placeholder, text: $repositoryURL)
                        .textFieldStyle(.plain)
                        .font(.mono(11.5))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .fieldSurface()
                        .onSubmit(loadRepository)
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

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(5)
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
