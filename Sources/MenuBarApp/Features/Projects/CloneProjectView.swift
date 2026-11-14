import SwiftUI

// Makes a project from a repository that is not on this Mac yet. The folder name follows
// the address until it is edited by hand, and the sheet stays open through the clone so
// a failure can be read and fixed in place.
struct CloneProjectView: View {
    let onCloned: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store

    @State private var remote = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var chosenFolder: URL?
    @State private var cloning: Task<Void, Never>?
    @State private var progress: GitClone.Progress?
    @State private var failure: Failure?
    @FocusState private var remoteFocused: Bool

    private struct Failure: Equatable {
        var message: String
        // The SSH address to try, when git could not sign in over HTTPS.
        var sshAddress: String? = nil
    }

    private enum Status: Equatable {
        case empty
        case ready(String)
        case taken(String)
        case cloning
        case failed(Failure)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Clone repository")
                    .font(Typography.display)
                Text("Copy a repository to this Mac and add it as a project.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                fieldRow("URL") {
                    // Verbatim, or the title is read as markdown and the address turns into
                    // a link.
                    TextField(text: $remote, prompt: Text(verbatim: "git@github.com:owner/repository.git")) {
                        Text("Repository URL")
                    }
                        .textFieldStyle(.plain)
                        .font(Font.mono(Typography.Size.body))
                        .focused($remoteFocused)
                }
                .padding(.top, Space.sm)

                fieldRow("FOLDER") {
                    Text(folder.path.abbreviatedPath)
                        .font(Font.mono(Typography.Size.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionButton(title: "Choose…", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.caption,
                                 action: chooseFolder)
                }

                fieldRow("NAME") {
                    TextField("Folder name", text: Binding(
                        get: { name },
                        set: { name = $0; nameEdited = !$0.isBlank }))
                        .textFieldStyle(.plain)
                        .font(Typography.body.weight(.semibold))
                }

                // Tall enough for every state but a long failure, so typing the first
                // character or starting the clone does not resize the sheet.
                statusLine
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .motion(Motion.reveal, value: status)
            }
            .disabled(isCloning)
            .padding(Space.xxl)

            SheetFooter(title: "The project opens when the clone finishes.",
                        primary: SheetAction(title: "Clone", enabled: canClone,
                                             shortcut: .defaultAction, action: clone),
                        dismiss: cancel)
        }
        .frame(width: 560)
        .background(Theme.background)
        .onAppear { remoteFocused = true }
        .onChange(of: remote) { _, address in
            failure = nil
            if !nameEdited { name = GitClone.folderName(for: address) ?? "" }
        }
        .onChange(of: name) { failure = nil }
        .onChange(of: chosenFolder) { failure = nil }
    }

    private func fieldRow<Field: View>(_ label: String,
                                       @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: Space.lg) {
            SectionLabel(label, style: .field)
                .frame(width: 50, alignment: .leading)
            field()
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 44)
        .fieldSurface(cornerRadius: Radius.card)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .empty:
            Text("Paste the address from the repository's Clone button.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .transition(.fadeIn)
        case .ready(let path):
            Text("Clones into \(path)")
                .font(Typography.data)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .transition(.fadeIn)
        case .taken(let path):
            Text("\(path) already exists. Pick another name or folder.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .warningCard()
        case .cloning:
            HStack(spacing: Space.md) {
                LoopSpinner()
                Text(progressText)
                    .font(Typography.detail.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motion(Motion.control, value: progress)
            }
            .transition(.fadeIn)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: Space.md) {
                Text(failure.message)
                    .fixedSize(horizontal: false, vertical: true)
                if let sshAddress = failure.sshAddress {
                    Button { remote = sshAddress } label: {
                        Text("Use \(sshAddress)")
                            .font(Typography.label)
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .warningCard()
        }
    }

    private var progressText: String {
        guard let progress else { return "Contacting the remote…" }
        return "\(progress.phase) \(progress.percent)%"
    }

    private var status: Status {
        if isCloning { return .cloning }
        if let failure { return .failed(failure) }
        guard let destination, !remote.isBlank else { return .empty }
        let path = destination.path.abbreviatedPath
        return FileManager.default.fileExists(atPath: destination.path) ? .taken(path) : .ready(path)
    }

    private var isCloning: Bool { cloning != nil }

    // The last folder cloned into, then the folder a project lives in, which is likely
    // where this person keeps their code. Each has to still exist: git would create a
    // missing one, and a failed clone would then leave it behind.
    private var folder: URL {
        if let chosenFolder { return chosenFolder }
        if let remembered = Preferences.cloneFolder,
           FileManager.default.fileExists(atPath: remembered) {
            return URL(fileURLWithPath: remembered, isDirectory: true)
        }
        let projectFolders = store.regularProjects.lazy.map {
            URL(fileURLWithPath: $0.path, isDirectory: true).deletingLastPathComponent()
        }
        if let projectFolder = projectFolders.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return projectFolder
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var destination: URL? {
        let folderName = name.trimmed
        guard GitClone.isUsableFolderName(folderName) else { return nil }
        return folder.appendingPathComponent(folderName, isDirectory: true)
    }

    // A failed clone can be tried again as it stands, since the fault is often the network.
    private var canClone: Bool {
        guard !isCloning, !remote.isBlank, let destination else { return false }
        return !FileManager.default.fileExists(atPath: destination.path)
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseFolder(prompt: "Choose",
                                                message: "Pick the folder the repository goes inside.",
                                                directory: folder) else { return }
        chosenFolder = url
    }

    private func clone() {
        guard canClone, let destination else { return }
        failure = nil
        progress = nil
        let target = folder
        let address = remote.trimmed
        cloning = Task {
            let outcome = await GitClone.clone(address, to: destination) { progress = $0 }
            switch outcome {
            case .cloned(let url):
                // Still shown as cloning while the sheet closes. The folder exists now, so
                // the idle state would flash the "already exists" warning.
                Preferences.cloneFolder = target.path
                onCloned(url)
                dismiss()
            case .failed(let message):
                cloning = nil
                failure = Failure(message: message)
            case .signInRequired(let signIn):
                cloning = nil
                failure = Failure(message: signIn.message, sshAddress: signIn.sshAddress)
            case .cancelled:
                cloning = nil
            }
        }
    }

    private func cancel() {
        cloning?.cancel()
        dismiss()
    }
}
