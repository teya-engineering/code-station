import SwiftUI

// macOS puts the button that closes a window at the bottom right, so every sheet ends
// with this bar instead of parking Done up in its title area where it reads like part of
// the toolbar. Escape closes as well, since Done never does anything but leave.
struct SheetFooter<Leading: View>: View {
    private let title: String
    private let leading: Leading
    private let done: () -> Void

    init(title: String = "Done",
         done: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.leading = leading()
        self.done = done
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                leading
                Spacer()
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
    init(title: String = "Done", done: @escaping () -> Void) {
        self.init(title: title, done: done) { EmptyView() }
    }
}
