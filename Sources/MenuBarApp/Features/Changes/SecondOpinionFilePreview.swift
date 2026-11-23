import SwiftUI

struct SecondOpinionFilePreview: View {
    let file: SecondOpinionAskFacts.File
    let scope: SecondOpinionRequest.Scope
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale
    @State private var patch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(file.name, icon: "doc.text")
                .padding(.horizontal, Space.pane).headerBand()
            Text(file.path).font(Typography.data).foregroundStyle(.secondary)
                .padding(Space.pane)
            if let patch {
                if patch.isEmpty {
                    PaneMessage(icon: "doc.text", title: "No text diff",
                                detail: "This file has no text changes in the selected comparison.")
                } else {
                    DiffTextView(text: DiffText.attributed(GitInspector.parse(patch, startingAt: 0, limit: GitInspector.diffLineLimit, revision: .workingTree, path: file.path).lines, scale: textScale, numbered: true))
                }
            } else {
                ChangesLoadingPlaceholder(title: "Reading file diff…").padding(Space.pane)
            }
            SheetFooter(dismiss: { dialogs.dismiss() })
        }
        .focusBoundary()
        .task {
            let request = SecondOpinionRequest(scope: scope,
                repositories: [ReviewRepository(root: file.root, name: (file.root as NSString).lastPathComponent)],
                executable: "")
            let patches = await SecondOpinion.patches(for: request)
            guard !Task.isCancelled else { return }
            patch = patches.first { $0.path == file.path && $0.root == file.root }?.text ?? ""
        }
    }
}
