import AppKit
import SwiftUI

// A key the person sets by pressing it. A click opens the cap to listen, and the next keys
// pressed are offered to the owner, who keeps them or says why not. Escape gives up,
// Delete takes the key away, and a click anywhere else stops listening.
struct KeyRecorder: View {
    let keys: KeyCombo?
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void
    let onClear: () -> Void

    @State private var hovering = false
    @State private var listener = KeyRecorderListener()

    var body: some View {
        Button { isRecording.toggle() } label: {
            Text(caption)
                .font(Typography.data.weight(.semibold))
                .foregroundStyle(isRecording ? AnyShapeStyle(Theme.accent)
                                 : keys == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .contentTransition(.opacity)
                .padding(.horizontal, Space.md)
                .frame(height: ControlHeight.sm)
                .surface(hovering || isRecording ? Theme.card : Theme.field,
                         cornerRadius: Radius.inset,
                         border: isRecording ? Theme.accent : Theme.border)
                .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: isRecording)
        .motion(Motion.control, value: keys)
        .background(KeyRecorderAnchor(listener: listener))
        .onChange(of: isRecording, initial: true) { _, recording in
            if recording {
                listener.start(
                    onKeys: onRecord,
                    onClear: {
                        onClear()
                        isRecording = false
                    },
                    onCancel: { isRecording = false })
            } else {
                listener.stop()
            }
        }
        .onDisappear {
            listener.stop()
            isRecording = false
        }
        .accessibilityLabel(keys.map { "Shortcut \($0.spokenLabel)" } ?? "No shortcut")
        .accessibilityHint(isRecording ? "Press the new keys. Escape cancels, Delete removes the shortcut."
                                       : "Change the shortcut")
    }

    private var caption: String {
        if isRecording { return "Press keys" }
        return keys?.label ?? "None"
    }
}

// Hears the keyboard only while its cap is listening. Every press is swallowed, so a key
// being recorded never also runs what it is bound to, or closes the sheet the cap is in.
@MainActor
final class KeyRecorderListener {
    weak var anchor: NSView?

    private var keyToken: Any?
    private var clickToken: Any?

    func start(onKeys: @escaping (KeyCombo) -> Void,
               onClear: @escaping () -> Void,
               onCancel: @escaping () -> Void) {
        stop()
        keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let pressed = KeyCombo(event: event)
            let window = event.window
            return MainActor.assumeIsolated { () -> Bool in
                guard let self, let anchor = self.anchor, window === anchor.window else { return false }
                if pressed == KeyCombo(KeyCombo.escape, []) {
                    onCancel()
                } else if pressed == KeyCombo(KeyCombo.delete, []) {
                    onClear()
                } else if let pressed {
                    onKeys(pressed)
                }
                return true
            } ? nil : event
        }
        // A click on the cap itself is left to the cap, which stops listening on its own.
        clickToken = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let window = event.window
            let point = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, let anchor = self.anchor else { return }
                let onCap = window === anchor.window
                    && anchor.bounds.contains(anchor.convert(point, from: nil))
                if !onCap { onCancel() }
            }
            return event
        }
    }

    func stop() {
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        if let clickToken { NSEvent.removeMonitor(clickToken) }
        keyToken = nil
        clickToken = nil
    }
}

// Covers the cap, so the listener knows its window and where a click landed.
private struct KeyRecorderAnchor: NSViewRepresentable {
    let listener: KeyRecorderListener

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        listener.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { listener.anchor = view }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
