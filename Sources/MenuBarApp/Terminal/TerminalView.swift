import AppKit
import SwiftTerm
import SwiftUI

// The output of one shell, and the keyboard that drives it. The real work happens in
// SwiftTerm; this wraps its view for SwiftUI and keeps focus behaving like the rest
// of the app.
struct TerminalScreen: View {
    let terminal: TerminalSession
    @Binding var isFocused: Bool

    var body: some View {
        TerminalHost(surface: terminal.surface, isFocused: $isFocused)
            .id(terminal.id)
            .background(Theme.background)
            .overlay {
                // A focused terminal draws a faint ring, so it is clear where typing goes.
                if isFocused {
                    Rectangle()
                        .stroke(Color(nsColor: Theme.focusRing), lineWidth: 2)
                        .padding(1)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let failure = terminal.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(ChatColor.warningText)
                        .padding(16)
                }
            }
    }
}

// Mounts the session's surface. The surface belongs to the session, not this view, so
// the screen and its scrollback survive the drawer closing; mounting is just moving
// the one view into whatever container is on screen right now.
private struct TerminalHost: NSViewRepresentable {
    let surface: TerminalSurface
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if surface.superview !== container { install(in: container) }
        surface.onFocusChange = { focused in
            // Clicking the terminal is another way of asking for it, so the binding has
            // to hear about focus the view took on its own.
            if isFocused != focused { isFocused = focused }
        }
        surface.wantsFocus = isFocused
        // Only ever claim focus, never clear it: handing it back to nobody would leave
        // the window with no first responder at all, and typing would go nowhere.
        // Whatever the user moves to next takes it from here on its own.
        if isFocused, surface.window?.firstResponder !== surface {
            DispatchQueue.main.async { surface.window?.makeFirstResponder(surface) }
        }
    }

    private func install(in container: NSView) {
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
    }
}

// SwiftTerm's view dressed in the app's palette, with the few keys the app keeps for
// itself carved out.
final class TerminalSurface: SwiftTerm.TerminalView {
    var onClear: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    // What the app wants, as opposed to what AppKit currently has. The two come apart
    // whenever the window stops being the key one.
    var wantsFocus = false

    // Written on the main actor only; marked unsafe so deinit may read them to tear
    // the observers down.
    nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
    private var responderObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var keyMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        applyTheme()
        interceptAppKeys()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyTheme()
        interceptAppKeys()
    }

    // The ANSI palette redrawn in the app's colours, so a terminal does not look
    // pasted in from somewhere else. The background is light, which is why "white"
    // is dark: it is the readable text colour, not the paper.
    private func applyTheme() {
        nativeBackgroundColor = NSColor(red: 0.965, green: 0.961, blue: 0.945, alpha: 1)
        nativeForegroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.14, alpha: 1)
        caretColor = NSColor(red: 0.20, green: 0.34, blue: 0.24, alpha: 1)
        caretTextColor = NSColor(red: 0.965, green: 0.961, blue: 0.945, alpha: 1)
        selectedTextBackgroundColor = NSColor(red: 0.20, green: 0.34, blue: 0.24, alpha: 0.22)
        installColors([
            Self.ansi(0.20, 0.20, 0.19),  // black
            Self.ansi(0.75, 0.28, 0.24),  // red, the diff deletion colour
            Self.ansi(0.24, 0.47, 0.29),  // green, the diff addition colour
            Self.ansi(0.72, 0.52, 0.20),  // yellow
            Self.ansi(0.24, 0.38, 0.60),  // blue
            Self.ansi(0.52, 0.30, 0.55),  // magenta
            Self.ansi(0.20, 0.48, 0.51),  // cyan
            Self.ansi(0.36, 0.36, 0.34),  // white
            Self.ansi(0.55, 0.55, 0.52),  // bright black
            Self.ansi(0.82, 0.36, 0.30),  // bright red
            Self.ansi(0.33, 0.56, 0.36),  // bright green
            Self.ansi(0.78, 0.60, 0.24),  // bright yellow
            Self.ansi(0.32, 0.47, 0.70),  // bright blue
            Self.ansi(0.62, 0.40, 0.64),  // bright magenta
            Self.ansi(0.26, 0.57, 0.60),  // bright cyan
            Self.ansi(0.15, 0.15, 0.14)   // bright white
        ])
    }

    private static func ansi(_ red: Double, _ green: Double, _ blue: Double) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red * 65535), green: UInt16(green * 65535), blue: UInt16(blue * 65535))
    }

    // MARK: - Keys the app keeps

    // SwiftTerm's key handling is sealed, so the app's few keys are taken before
    // dispatch instead: a monitor sees every key press ahead of the responder chain,
    // and steps in only while this terminal is the one being typed into.
    private func interceptAppKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window?.firstResponder === self,
                      event.window === self.window else { return false }
                let flags = event.modifierFlags
                if flags.contains(.command), event.charactersIgnoringModifiers == "k" {
                    self.onClear?()
                    return true
                }
                // Control-backtick belongs to the app, which uses it to move focus;
                // passed on up the chain rather than into the shell.
                if flags.contains(.control), event.charactersIgnoringModifiers == "`" {
                    self.nextResponder?.keyDown(with: event)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    // MARK: - Focus

    // The responder overrides are sealed too, so focus is tracked from the outside:
    // the window says who the first responder is, and this view compares that to
    // itself.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
        responderObservation = nil
        guard let window else { return }

        responderObservation = window.observe(\.firstResponder, options: [.old, .new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (change.newValue ?? nil) === self {
                    self.onFocusChange?(true)
                } else if (change.oldValue ?? nil) === self, self.window?.isKeyWindow == true {
                    // A window merely losing key status is not the user moving focus
                    // elsewhere, so the terminal keeps its claim and takes the
                    // keyboard back on return.
                    self.onFocusChange?(false)
                }
            }
        }

        // Switching to another app and back must not cost the terminal its keyboard.
        // AppKit does not restore a first responder on its own here, so the claim is
        // made again as soon as the window is key.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsFocus, self.window?.firstResponder !== self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
