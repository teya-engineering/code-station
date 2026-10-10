import SwiftUI

struct WorkspaceChangesView: View {
    let session: ChatSession
    let initialRoot: String
    let initialPath: String?
    @Environment(ProjectStore.self) private var store
    @Binding var selectedRoot: String
    let navigation: ChangesNavigationMemory
    // The file someone asked to open, from outside or from another project's row. Once
    // they move to another project it is served, so coming back opens on whatever was
    // last picked there instead of on this file again.
    @State private var request: ChangesNavigatorItem?

    init(session: ChatSession, initialRoot: String, initialPath: String?,
         selectedRoot: Binding<String>, navigation: ChangesNavigationMemory) {
        self.session = session
        self.initialRoot = initialRoot
        self.initialPath = initialPath
        _selectedRoot = selectedRoot
        self.navigation = navigation
        _request = State(initialValue: ChangesNavigatorItem(root: initialRoot, path: initialPath))
    }

    private var roots: [String] {
        let directories = store.workingDirectories(for: session)
        return directories.contains(initialRoot) ? directories : [initialRoot] + directories
    }

    // Only the open project gets a screen. The others are listed in its navigator from the
    // shared git cache, and what a screen has to remember when you move between projects
    // is kept in the navigation memory, so a project opens where it was left.
    var body: some View {
        ChangesView(root: selectedRoot,
                    repositories: roots.map { ChangesRepository(root: $0, name: name($0)) },
                    requestedPath: request?.root == selectedRoot ? request?.path : nil,
                    navigation: navigation) { root, path in
            request = ChangesNavigatorItem(root: root, path: path)
            selectedRoot = root
        }
        .id(selectedRoot)
        .onChange(of: ChangesNavigatorItem(root: initialRoot, path: initialPath)) { _, item in
            if item.path != nil { request = item }
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
