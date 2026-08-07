import SwiftUI

// What a sheet's Save does, and whether there is anything to save right now.
struct SheetSave {
    let enabled: Bool
    let action: () -> Void
}

// macOS puts the button that closes a window at the bottom right, so every sheet ends
// with this bar instead of parking Done up in its title area where it reads like part of
// the toolbar. Escape closes as well, since Done never does anything but leave.
//
// A sheet that edits something can put a Save next to Done. It only lights up while
// there are unsaved changes, and answers to Cmd-S and Ctrl-S as well.
struct SheetFooter<Leading: View>: View {
    private let title: String
    private let leading: Leading
    private let done: () -> Void
    private let save: SheetSave?

    init(title: String = "Done",
         save: SheetSave? = nil,
         done: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.leading = leading()
        self.done = done
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                leading
                Spacer()
                if let save {
                    Button(action: save.action) {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!save.enabled)
                    .opacity(save.enabled ? 1 : 0.4)
                    // The Mac shortcut is Cmd-S, but fingers trained elsewhere press
                    // Ctrl-S; both land on the same save.
                    .background(
                        Button(action: save.action) { Text("") }
                            .buttonStyle(.plain)
                            .keyboardShortcut("s", modifiers: .control)
                            .disabled(!save.enabled)
                            .opacity(0)
                    )
                }
                Button(action: done) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }
}

extension SheetFooter where Leading == EmptyView {
    init(title: String = "Done", save: SheetSave? = nil, done: @escaping () -> Void) {
        self.init(title: title, save: save, done: done) { EmptyView() }
    }
}
