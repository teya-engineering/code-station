import Foundation

// Coalesces a burst of changes into one write. Typing in a field is one change per
// keystroke, so a store saves once the keystrokes stop rather than once per key.
@MainActor
final class DebouncedSaver {
    private let delay: Duration
    private let save: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    // The closure lives as long as the store that owns the saver, so it should capture
    // that store weakly or the two keep each other alive.
    init(delay: Duration = .milliseconds(400), save: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.save = save
    }

    var isPending: Bool { pending != nil }

    // Starts the wait over, so the write lands after the last change rather than the first.
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            pending = nil
            save()
        }
    }

    // Writes a change that is still waiting, so readers of the file and the app's last
    // moments see what is on screen.
    func flush() {
        guard isPending else { return }
        cancel()
        save()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
