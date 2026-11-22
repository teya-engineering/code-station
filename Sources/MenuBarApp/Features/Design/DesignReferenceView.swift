import SwiftUI

struct DesignReferenceView: View {
    @Environment(ProjectStore.self) private var store

    let sessionID: UUID

    @State private var canvas = DesignCanvas()
    @State private var designWindow = DesignWindow()

    var body: some View {
        if let session = store.session(sessionID),
           let directory = store.implementationDesignDirectory(for: session) {
            VStack(spacing: 0) {
                DesignCanvasBar(canvas: canvas) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text("APPROVED DESIGN")
                        .font(Typography.caps)
                        .kerning(1)
                    if let title = revisionTitle(session) {
                        MonoChip(text: title.uppercased(), size: Typography.Size.micro, tint: Theme.accent)
                    }
                } tools: {
                    if let sourceID = session.sourceDesignSessionID,
                       store.session(sourceID) != nil {
                        ActionButton(title: "Edit Design", tone: .outlined,
                                     height: ControlHeight.md, size: Typography.Size.caption, icon: "arrow.up.right") {
                            store.selectSession(sourceID)
                        }
                    }

                    if canvas.revision != nil {
                        ActionButton(title: "Full Screen",
                                     tone: designWindow.isOpen ? .sunken : .outlined,
                                     height: ControlHeight.md, size: Typography.Size.caption, icon: "macwindow") {
                            openDesignWindow(session, directory: directory)
                        }
                        .appTooltip(designWindow.isOpen
                            ? "Bring design window to front"
                            : "Open design in a separate window")
                    }
                }

                if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                    DesignWebView(
                        url: url,
                        readAccessURL: directory,
                        screen: canvas.selectedScreen,
                        revision: revision,
                        reloadGeneration: canvas.reloadGeneration,
                        selectionEnabled: false,
                        snapshotRequest: nil,
                        onSelection: { _ in },
                        onSnapshot: { _, _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                } else {
                    unavailable(session)
                }
            }
            .task(id: directory.path) { await canvas.watch(directory) }
            .onDisappear { designWindow.close() }
        } else {
            unavailable(store.session(sessionID))
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: revisionTitle(session) ?? "Approved design",
                                      onClose: { designWindow.close() }))
    }

    // Whether there is a way out of this depends on the Design the session was handed:
    // one that is still around can be opened and handed off again, while a deleted one
    // leaves nothing to point at, so saying otherwise would send the reader hunting.
    @ViewBuilder private func unavailable(_ session: ChatSession?) -> some View {
        let title = "The Design reference is unavailable"
        if let sourceID = session?.sourceDesignSessionID, store.session(sourceID) != nil {
            PaneMessage(icon: "paintbrush.pointed", title: title,
                        detail: "Return to the source Design and create another handoff.") {
                ActionButton(title: "Open Design", tone: .outlined, icon: "arrow.up.right") {
                    store.selectSession(sourceID)
                }
                .padding(.top, Space.xs)
            }
        } else {
            PaneMessage(
                icon: "paintbrush.pointed", title: title,
                detail: "The Design session it came from has been deleted, so there is nothing left to show here. The work in this session is unaffected.")
        }
    }

    private func revisionTitle(_ session: ChatSession) -> String? {
        if let revisionID = session.handedOffDesignRevisionID,
           let sourceSessionID = session.sourceDesignSessionID,
           let sourceSession = store.session(sourceSessionID),
           let revision = sourceSession.designRevisions.first(where: { $0.id == revisionID }) {
            return revision.title
        }
        if let revision = store.approvedDesignRevision(for: session) { return revision.title }
        return session.handedOffDesignRevisionID == nil ? nil : "Approved"
    }
}
