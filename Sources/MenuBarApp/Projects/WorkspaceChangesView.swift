import SwiftUI

struct WorkspaceChangesView: View {
    let session: ChatSession
    let initialRoot: String
    let initialPath: String?
    @Environment(ProjectStore.self) private var store
    @Binding var selectedRoot: String
    let navigation: ChangesNavigationMemory
    @State private var selectedPath: String?

    private var roots: [String] {
        let directories = store.workingDirectories(for: session)
        return directories.contains(initialRoot) ? directories : [initialRoot] + directories
    }
    private var selected: String { selectedRoot }

    var body: some View {
        ZStack {
            ForEach(roots, id: \.self) { root in
                ChangesView(root: root,
                            initiallySelectedPath: root == initialRoot ? initialPath : nil,
                            repositories: roots.map { ChangesRepository(root: $0, name: name($0)) },
                            requestedPath: selectedRoot == root ? selectedPath ?? (root == initialRoot ? initialPath : nil) : nil,
                            navigation: navigation) { root, path in
                    selectedPath = path
                    selectedRoot = root
                }
                .opacity(root == selected ? 1 : 0)
                .allowsHitTesting(root == selected)
                .disabled(root != selected)
                .accessibilityHidden(root != selected)
            }
        }
        .onChange(of: ChangesNavigatorItem(root: initialRoot, path: initialPath)) { _, request in
            if let path = request.path { selectedPath = path }
        }
    }

    private func name(_ root: String) -> String {
        for checkout in store.checkoutProjects(for: session) {
            if let project = store.project(checkout.projectID), (checkout.worktreePath ?? project.path) == root {
                return project.name
            }
        }
        return (root as NSString).lastPathComponent
    }
}
