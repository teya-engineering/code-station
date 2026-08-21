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
    @State private var chosen: Set<SiteConfigurationItem> = []
    @State private var reviewing = false
    @State private var repositoryURL = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var editing = false

    private var hasConfiguration: Bool { loaded.sourceURL != nil }

    var body: some View {
        ChoiceBlock("SITE CONFIGURATION",
                    note: "The shared file behind your environments, starter requests, Grafana instances, skills marketplace and shortcuts. Import a team file or edit the JSON kept on this Mac.") {
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
        .sheet(isPresented: $editing) {
            SiteConfigurationEditorView(defaults: loaded, onSave: apply)
                .appOverlays()
        }
    }

    private var current: some View {
        HStack(alignment: .top, spacing: 12) {
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
            Spacer(minLength: 0)
            ActionButton(title: hasConfiguration ? "Edit JSON…" : "Create JSON…",
                         tone: .outlined,
                         icon: "curlybraces",
                         action: { editing = true })
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
        let plan = selection.plan
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.sourceName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reviewing ? chosenCount(plan) : selection.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !plan.isEmpty {
                    ActionButton(title: reviewing ? "Hide" : "Review", tone: .outlined) {
                        reviewing.toggle()
                    }
                }
                ActionButton(title: hasConfiguration ? "Replace" : "Use") {
                    install(selection)
                }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
            }
            if reviewing { review(plan) }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.addition.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.addition.opacity(0.28)))
    }

    // A file is one document, but its parts are unrelated: a team's Grafana instances can
    // be worth taking on a machine where the starter requests would bury the ones already
    // saved. Everything starts ticked, so reviewing costs nothing to whoever wants it all.
    private func review(_ plan: SiteConfigurationPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Theme.border)
            ForEach(plan.groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(allChosen(in: group) ? "Clear" : "All") {
                            toggle(group, on: !allChosen(in: group))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    ForEach(group.items) { item in
                        Toggle(isOn: binding(for: item.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(item.detail)
                                    .font(.mono(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.appCheckbox)
                    }
                }
            }
        }
    }

    private func chosenCount(_ plan: SiteConfigurationPlan) -> String {
        let total = plan.items.count
        let word = "part\(total == 1 ? "" : "s")"
        return chosen.count == total
            ? "All \(total) \(word) will be used."
            : "\(chosen.count) of \(total) \(word) will be used."
    }

    private func allChosen(in group: SiteConfigurationPlan.Group) -> Bool {
        group.items.allSatisfy { chosen.contains($0.id) }
    }

    private func toggle(_ group: SiteConfigurationPlan.Group, on: Bool) {
        for item in group.items {
            if on { chosen.insert(item.id) } else { chosen.remove(item.id) }
        }
    }

    private func binding(for item: SiteConfigurationItem) -> Binding<Bool> {
        Binding(get: { chosen.contains(item) },
                set: { keep in
                    if keep { chosen.insert(item) } else { chosen.remove(item) }
                })
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
                offer(try await SiteConfigurationImporter.load(gitHubRepository: repository))
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func record(_ load: () throws -> SiteConfigurationSelection) {
        do {
            offer(try load())
            failure = nil
        } catch {
            pending = nil
            failure = error.localizedDescription
        }
    }

    private func offer(_ selection: SiteConfigurationSelection) {
        pending = selection
        chosen = selection.plan.everything
        reviewing = false
    }

    // The stores hold their own copy of what the file said, so they are handed the new
    // one rather than left showing the setup that has just been replaced.
    private func install(_ selection: SiteConfigurationSelection) {
        do {
            let defaults = try SiteConfigurationImporter.install(selection, keeping: chosen)
            apply(defaults)
            pending = nil
            chosen = []
            reviewing = false
            repositoryURL = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func apply(_ defaults: SiteDefaults) {
        dispatch.applySiteDefaults(defaults)
        dispatchAuth.applySiteDefaults(defaults)
        shortcuts.applySiteDefaults(defaults)
        loaded = defaults
    }
}

// The site document is deliberately edited as JSON. Several of its values have focused
// editors elsewhere, while others are only shared defaults, and keeping one source here
// avoids two forms that can disagree. Saving validates everything the app understands and
// leaves unknown fields intact for newer versions.
private struct SiteConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let destination: URL
    private let sourceName: String
    private let onSave: (SiteDefaults) -> Void

    @State private var text: String
    @State private var savedText: String
    @State private var failure: String?

    init(defaults: SiteDefaults, onSave: @escaping (SiteDefaults) -> Void) {
        let destination = Self.editDestination(defaults)
        let initial = Self.load(defaults, destination: destination)
        self.destination = destination
        sourceName = destination.path
        self.onSave = onSave
        _text = State(initialValue: initial.text)
        _savedText = State(initialValue: initial.text)
        _failure = State(initialValue: initial.failure)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit site configuration").font(.serif(16))
                Text("Changes are validated and saved to this Mac. Personal secrets do not belong in this file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()

            VStack(alignment: .leading, spacing: 10) {
                Text(sourceName.abbreviatedPath)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                CodeEditorView(documentID: sourceName,
                               text: $text,
                               language: .json,
                               matches: [],
                               currentMatch: nil)
                    .frame(height: 440)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            SheetFooter(save: SheetSave(enabled: text != savedText, action: save),
                        done: { dismiss() }) {
                if text != savedText {
                    Text("Unsaved changes. Done leaves without keeping them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 720)
        .background(Theme.background)
    }

    private func save() {
        do {
            let defaults = try SiteConfigurationImporter.install(editedText: text,
                                                                  at: destination)
            savedText = text
            failure = nil
            onSave(defaults)
        } catch {
            failure = error.localizedDescription
        }
    }

    private static func editDestination(_ defaults: SiteDefaults) -> URL {
        if let environment = SiteDefaults.environmentURL {
            return environment
        }
        guard let source = defaults.sourceURL else {
            return SiteConfigurationImporter.destination
        }
        if source.standardizedFileURL == SiteDefaults.bundledURL?.standardizedFileURL {
            return SiteConfigurationImporter.destination
        }
        return source
    }

    private static func load(_ defaults: SiteDefaults,
                             destination: URL) -> (text: String, failure: String?) {
        let source = FileManager.default.fileExists(atPath: destination.path)
            ? destination : defaults.sourceURL
        guard let source else { return ("{}\n", nil) }
        do {
            let data = try Data(contentsOf: source)
            guard let text = String(data: data, encoding: .utf8) else {
                return ("{}\n", "The configuration is not UTF-8 text and cannot be edited here.")
            }
            return (text, nil)
        } catch {
            return ("{}\n", "The configuration could not be read: \(error.localizedDescription)")
        }
    }
}
