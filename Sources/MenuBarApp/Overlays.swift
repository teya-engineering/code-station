import SwiftUI

// Dialogs and menus are drawn by the app, so they need somewhere to be drawn. Both are
// placed at the top of whatever they belong to rather than where they were asked for, so
// a question from the sidebar is still centred over the whole window and a menu can spill
// past the panel it was opened from.
//
// A sheet is a separate window stacked over the main one, so the window's own layer is
// underneath it and cannot be seen from inside. Every sheet that asks a question gets a
// layer of its own; each one holds its own presenters, so the dialog appears over the
// thing that asked for it.
extension View {
    func appOverlays() -> some View {
        modifier(AppOverlays())
    }
}

private struct AppOverlays: ViewModifier {
    @State private var dialogs = DialogPresenter()
    @State private var menus = MenuPresenter()

    func body(content: Content) -> some View {
        content
            .overlay { ContextMenuHost() }
            .overlay { DialogHost() }
            .environment(dialogs)
            .environment(menus)
    }
}
