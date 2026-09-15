import AppKit
import SwiftTerm
import SwiftUI

// The output of one shell, and the keyboard that drives it. The real work happens in
// SwiftTerm; this wraps its view for SwiftUI and keeps focus behaving like the rest
// of the app.
struct TerminalScreen: View {
    @Environment(\.textScale) private var textScale
    // A dialog and a menu are drawn inside the window and answer the keyboard
    // themselves, so the shell stands back while one is up. Both are optional because a
    // shell can also be hosted by a sheet that carries no overlays of its own.
    @Environment(DialogPresenter.self) private var dialogs: DialogPresenter?
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?

    let terminal: TerminalSession
    @Binding var isFocused: Bool

    var body: some View {
        TerminalHost(surface: terminal.surface, isFocused: $isFocused, textScale: textScale,
                     claimsKeys: dialogs?.current == nil && menus?.isOpen != true)
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
                        .scaledText(12)
                        .foregroundStyle(Theme.warningText)
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
    let textScale: CGFloat
    let claimsKeys: Bool

    func makeNSView(context: Context) -> NSView {
        surface.applyTextScale(textScale)
        surface.claimsKeys = claimsKeys
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if surface.superview !== container { install(in: container) }
        surface.claimsKeys = claimsKeys
        // Resizing the type reflows the shell, so this only runs when the size has
        // actually changed rather than on every pass through here.
        surface.applyTextScale(textScale)
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
    // Whether the shell is the one being typed into, or something the app has drawn over
    // it is. Only the view layer can tell, so it says.
    var claimsKeys = true
    // What the app wants, as opposed to what AppKit currently has. The two come apart
    // whenever the window stops being the key one.
    var wantsFocus = false

    // Written on the main actor only; marked unsafe so deinit may read them to tear
    // the observers down.
    nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
    private var responderObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var keyMonitor: Any?

    // The size the shell's own text is drawn at, before the reading scale is applied.
    private static let baseFontSize: CGFloat = 12
    private var textScale: CGFloat = 1

    // Changing the font changes how many columns and rows fit, which SwiftTerm turns into
    // a window size the running program is told about, so the shell reflows on its own.
    func applyTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        font = NSFont.monospacedSystemFont(ofSize: Self.baseFontSize * scale, weight: .regular)
    }

    override init(frame: NSRect) {
        super.init(frame: frame,
                   font: NSFont.monospacedSystemFont(ofSize: Self.baseFontSize, weight: .regular))
        applyTheme()
        interceptAppKeys()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyTheme()
        interceptAppKeys()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    // SwiftTerm bakes its palette into renderer colours, so an adaptive NSColor cannot
    // follow an appearance change on its own. Every colour is resolved for the current
    // appearance here, and reinstalling the palette redraws existing scrollback as well
    // as new output.
    private func applyTheme() {
        let palette: TerminalPalette = Theme.isDark(effectiveAppearance) ? .dark : .light
        nativeBackgroundColor = resolved(palette.background)
        nativeForegroundColor = resolved(palette.foreground)
        caretColor = resolved(palette.caret)
        caretTextColor = resolved(palette.background)
        selectedTextBackgroundColor = resolved(palette.selectionBackground)
        selectedTextForegroundColor = resolved(palette.selectionForeground)
        installColors(palette.ansi.map(TerminalPalette.ansi))
        needsDisplay = true
    }

    private func resolved(_ color: NSColor) -> NSColor {
        var fixed = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fixed = color.usingColorSpace(.sRGB) ?? color
        }
        return fixed
    }

    // MARK: - Keys

    // Where one key press goes while the shell holds the keyboard. Command belongs to
    // the app, which is where a Mac shortcut lives and what keeps Copy, Paste and Quit
    // working over a terminal; everything else belongs to the shell, because Escape,
    // Control-C and the rest are how a terminal is driven.
    enum KeyRoute: Equatable {
        case shell
        case app
        case clear
        case focusOut
    }

    static func route(_ event: NSEvent, claimsKeys: Bool) -> KeyRoute {
        guard claimsKeys else { return .app }
        let characters = event.charactersIgnoringModifiers
        if event.modifierFlags.contains(.command) {
            // Clearing the screen is the one Command key the shell answers.
            return characters == "k" ? .clear : .app
        }
        // Control-backtick is the way back out of a focused terminal, so the app keeps
        // it. Nothing else would be left to move focus with.
        if event.modifierFlags.contains(.control), characters == "`" { return .focusOut }
        return .shell
    }

    // Both SwiftTerm's key handling and the responder chain are reached too late to make
    // that split: a menu item and the hidden button behind a SwiftUI keyboard shortcut
    // are each offered a key press before the first responder sees it, so a plain Escape
    // or a Control key bound anywhere else in the window would never arrive. A monitor
    // runs ahead of both, and hands the shell its keys directly.
    private func interceptAppKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window?.firstResponder === self,
                      event.window === self.window else { return false }
                switch Self.route(event, claimsKeys: self.claimsKeys) {
                case .app:
                    return false
                case .clear:
                    self.onClear?()
                case .focusOut:
                    self.nextResponder?.keyDown(with: event)
                case .shell:
                    self.keyDown(with: event)
                }
                return true
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

// The colours the shell draws with, one table per appearance. The dark table shares the
// window's canvas and accent, so the terminal sits flush with the pane around it; those
// are adaptive colours, which land on their dark values because the table is only ever
// applied under a dark appearance. The light table is warmer than the window and keeps
// values of its own.
private struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    // The sixteen ANSI colours in their standard order: the eight normal ones, then the
    // bright set.
    let ansi: [(Double, Double, Double)]

    static let dark = TerminalPalette(
        background: Theme.backgroundNSColor,
        foreground: NSColor(srgbRed: 0.88, green: 0.87, blue: 0.84, alpha: 1),
        caret: Theme.accentNSColor,
        selectionBackground: NSColor(srgbRed: 0.23, green: 0.30, blue: 0.24, alpha: 1),
        selectionForeground: NSColor(srgbRed: 0.94, green: 0.93, blue: 0.90, alpha: 1),
        ansi: [
            (0.15, 0.15, 0.14),  // black
            (0.86, 0.40, 0.35),  // red
            (0.50, 0.72, 0.52),  // green
            (0.88, 0.68, 0.35),  // yellow
            (0.52, 0.65, 0.86),  // blue
            (0.75, 0.55, 0.78),  // magenta
            (0.43, 0.72, 0.74),  // cyan
            (0.80, 0.80, 0.77),  // white
            (0.45, 0.45, 0.42),  // bright black
            (0.96, 0.63, 0.58),  // bright red
            (0.60, 0.80, 0.61),  // bright green
            (0.94, 0.77, 0.45),  // bright yellow
            (0.62, 0.73, 0.93),  // bright blue
            (0.84, 0.65, 0.86),  // bright magenta
            (0.56, 0.80, 0.81),  // bright cyan
            (0.94, 0.94, 0.91)   // bright white
        ])

    static let light = TerminalPalette(
        background: NSColor(srgbRed: 0.965, green: 0.961, blue: 0.945, alpha: 1),
        foreground: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.14, alpha: 1),
        caret: NSColor(srgbRed: 0.20, green: 0.34, blue: 0.24, alpha: 1),
        selectionBackground: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.79, alpha: 1),
        selectionForeground: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.14, alpha: 1),
        ansi: [
            (0.20, 0.20, 0.19),  // black
            (0.75, 0.28, 0.24),  // red
            (0.24, 0.47, 0.29),  // green
            (0.72, 0.52, 0.20),  // yellow
            (0.24, 0.38, 0.60),  // blue
            (0.52, 0.30, 0.55),  // magenta
            (0.20, 0.48, 0.51),  // cyan
            (0.36, 0.36, 0.34),  // white
            (0.55, 0.55, 0.52),  // bright black
            (0.82, 0.36, 0.30),  // bright red
            (0.33, 0.56, 0.36),  // bright green
            (0.78, 0.60, 0.24),  // bright yellow
            (0.32, 0.47, 0.70),  // bright blue
            (0.62, 0.40, 0.64),  // bright magenta
            (0.26, 0.57, 0.60),  // bright cyan
            (0.15, 0.15, 0.14)   // bright white
        ])

    static func ansi(_ rgb: (Double, Double, Double)) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(rgb.0 * 65535), green: UInt16(rgb.1 * 65535),
                        blue: UInt16(rgb.2 * 65535))
    }
}
