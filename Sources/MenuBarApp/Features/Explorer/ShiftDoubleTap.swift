import AppKit
import SwiftUI

struct ShiftDoubleTapDetector {
    static let maximumInterval: TimeInterval = 0.5

    private var previousTap: TimeInterval?

    mutating func registerTap(at timestamp: TimeInterval) -> Bool {
        if let previousTap, timestamp - previousTap <= Self.maximumInterval {
            self.previousTap = nil
            return true
        }
        previousTap = timestamp
        return false
    }

    mutating func reset() {
        previousTap = nil
    }
}

struct ExplorerSearchShortcut: NSViewRepresentable {
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.onOpen = onOpen
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var onOpen: () -> Void

        private var detector = ShiftDoubleTapDetector()
        private var token: Any?

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                let shouldOpen = MainActor.assumeIsolated { self.handle(event) }
                if shouldOpen {
                    DispatchQueue.main.async { self.onOpen() }
                }
                return event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === anchor?.window else {
                detector.reset()
                return false
            }
            guard event.type == .flagsChanged,
                  event.keyCode == 56 || event.keyCode == 60 else {
                detector.reset()
                return false
            }
            guard event.modifierFlags.contains(.shift) else { return false }
            return detector.registerTap(at: event.timestamp)
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            detector.reset()
        }
    }
}
