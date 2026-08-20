import AppKit
import SwiftUI

// Where the organisation's shared setup came from, and how to replace it. The first-run
// wizard is the only other place that loads one, so without this an install that finished
// onboarding before its team had a settings file, or before the file grew a section, has
// no way to pick one up: the parts of the app the file feeds simply stay empty.
struct SiteConfigurationSection: View {
    @Environment(DispatchStore.self) private var dispatch
    @Environment(DispatchAuthStore.self) private var dispatchAuth
    @Environment(ShortcutStore.self) private var shortcuts

    @State private var loaded = SiteDefaults.current
    @State private var pending: SiteConfigurationSelection?
    @State private var repositoryURL = ""
    @State private var loading = false
    @State private var failure: String?

    private var hasConfiguration: Bool { loaded.sourceURL != nil }

    var body: some View {
        ChoiceBlock("SITE CONFIGURATION",
                    note: "The shared file behind your starter requests, Grafana instances, skills marketplace and shortcuts. A repository can provide site-defaults.json, teya-defaults.json, or one root-level JSON file.") {
            VStack(alignment: .leading, spacing: 10) {
                current
                sources
                if let pending { preview(pending) }
                if let failure { warning(failure, tone: Theme.deletion) }
                if let loadFailure = loaded.loadFailure { warning(loadFailure, tone: Theme.deletion) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasConfiguration ? "Loaded" : "No configuration loaded")
                .font(.system(size: 13, weight: .semibold))
            Text(hasConfiguration
                 ? loaded.summary
                 : "The app is running on its own empty defaults, so anything the file would fill in is missing.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let source = loaded.sourceURL {
                Text(source.path.abbreviatedPath)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var sources: some View {
        HStack(spacing: 8) {
            TextField("https://github.com/org/settings", text: $repositoryURL)
                .textFieldStyle(.plain)
                .font(.mono(11.5))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .onSubmit(loadRepository)
            ActionButton(title: loading ? "Loading…" : "Load",
                         tone: .outlined,
                         action: loadRepository)
                .disabled(loading || repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(loading ? 0.6 : 1)
            ActionButton(title: "Choose file…",
                         tone: .outlined,
                         icon: "folder",
                         action: chooseFile)
                .disabled(loading)
        }
    }

    // Loading only reads the file. Nothing is written until this is confirmed, so a file
    // that turns out to be the wrong one costs a look rather than the setup in place.
    private func preview(_ selection: SiteConfigurationSelection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.sourceName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(selection.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ActionButton(title: hasConfiguration ? "Replace" : "Use") {
                install(selection)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.addition.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.addition.opacity(0.28)))
    }

    private func warning(_ message: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tone)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(tone.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tone.opacity(0.25)))
    }

    private func chooseFile() {
        guard !loading else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Load"
        panel.message = "Choose the JSON file containing your organisation's shared Code Station setup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        record { try SiteConfigurationImporter.load(file: url) }
    }

    private func loadRepository() {
        let repository = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loading, !repository.isEmpty else { return }
        loading = true
        failure = nil
        pending = nil
        Task {
            do {
                pending = try await SiteConfigurationImporter.load(gitHubRepository: repository)
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func record(_ load: () throws -> SiteConfigurationSelection) {
        do {
            pending = try load()
            failure = nil
        } catch {
            pending = nil
            failure = error.localizedDescription
        }
    }

    // The stores hold their own copy of what the file said, so they are handed the new
    // one rather than left showing the setup that has just been replaced.
    private func install(_ selection: SiteConfigurationSelection) {
        do {
            let defaults = try SiteConfigurationImporter.install(selection)
            dispatch.applySiteDefaults(defaults)
            dispatchAuth.applySiteDefaults(defaults)
            shortcuts.applySiteDefaults(defaults)
            loaded = defaults
            pending = nil
            repositoryURL = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
