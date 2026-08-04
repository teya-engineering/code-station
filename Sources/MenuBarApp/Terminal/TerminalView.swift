import AppKit
import SwiftUI

// The output of one shell, and the keyboard that drives it.
struct TerminalScreen: View {
    let terminal: TerminalSession
    @Binding var isFocused: Bool

    private static let fontSize: CGFloat = 12
    private static let lineHeight: CGFloat = 17

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(terminal.lines) { line in
                            row(line)
                        }
                        Color.clear.frame(height: 1).id("terminal-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: terminal.lines.count) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
                .onChange(of: terminal.lines.last) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
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
            // The key catcher sits behind the text so selecting output still works, and
            // takes focus whenever the terminal is clicked.
            .background(
                TerminalKeyCatcher(
                    isFocused: $isFocused,
                    onText: { terminal.send($0) },
                    onBytes: { terminal.sendBytes($0) },
                    onClear: { terminal.clear() })
            )
            .onAppear { resize(in: geometry.size) }
            .onChange(of: geometry.size) { resize(in: $1) }
        }
        .background(Theme.background)
    }

    private func row(_ line: TerminalLine) -> some View {
        // An empty line still needs its height, or output with blank lines collapses.
        Text(line.spans.isEmpty ? AttributedString(" ") : attributed(line))
            .frame(height: Self.lineHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // AttributedString rather than concatenated Text: it is the only one of the two
    // that can paint a background, which is how the cursor block and inverse text are
    // drawn.
    private func attributed(_ line: TerminalLine) -> AttributedString {
        var result = AttributedString()
        for span in line.spans {
            var piece = AttributedString(span.text)
            let style = span.style
            piece.font = .mono(Self.fontSize, style.bold ? .semibold : .regular)
            let foreground = TerminalPalette.color(style.color, bold: style.bold)
            if style.inverse {
                piece.foregroundColor = Theme.background
                piece.backgroundColor = foreground
            } else {
                piece.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground
                if let background = style.background {
                    piece.backgroundColor = TerminalPalette.color(background, bold: false).opacity(0.22)
                }
            }
            if style.underline { piece.underlineStyle = .single }
            result.append(piece)
        }
        return result
    }

    // The shell has to be told the real size or anything that draws a full line wraps
    // in the wrong place.
    private func resize(in size: CGSize) {
        let font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0 else { return }
        let columns = Int((size.width - 32) / advance)
        let rows = Int((size.height - 16) / Self.lineHeight)
        terminal.resize(columns: max(columns, 20), rows: max(rows, 4))
    }
}

// ANSI colours drawn in the app's own palette, so a terminal does not look pasted in
// from somewhere else.
enum TerminalPalette {
    static func color(_ colour: TerminalColor?, bold: Bool) -> Color {
        guard let colour else { return .primary }
        switch colour {
        case .black: return Color(red: 0.20, green: 0.20, blue: 0.19)
        case .red: return Theme.deletion
        case .green: return Theme.addition
        case .yellow: return Theme.secret
        case .blue: return Color(red: 0.24, green: 0.38, blue: 0.60)
        case .magenta: return Color(red: 0.52, green: 0.30, blue: 0.55)
        case .cyan: return Color(red: 0.20, green: 0.48, blue: 0.51)
        case .white: return Color(red: 0.36, green: 0.36, blue: 0.34)
        case .brightBlack: return Color(red: 0.55, green: 0.55, blue: 0.52)
        case .brightRed: return Color(red: 0.82, green: 0.36, blue: 0.30)
        case .brightGreen: return Color(red: 0.33, green: 0.56, blue: 0.36)
        case .brightYellow: return Color(red: 0.78, green: 0.60, blue: 0.24)
        case .brightBlue: return Color(red: 0.32, green: 0.47, blue: 0.70)
        case .brightMagenta: return Color(red: 0.62, green: 0.40, blue: 0.64)
        case .brightCyan: return Color(red: 0.26, green: 0.57, blue: 0.60)
        case .brightWhite: return Color(red: 0.15, green: 0.15, blue: 0.14)
        }
    }
}

// Keyboard input for the terminal. SwiftUI has no way to read raw key presses, so a
// small NSView takes first responder and turns each press into the bytes a tty expects.
private struct TerminalKeyCatcher: NSViewRepresentable {
    @Binding var isFocused: Bool
    let onText: (String) -> Void
    let onBytes: (Data) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.apply(onText: onText, onBytes: onBytes, onClear: onClear)
        view.onFocusChange = { focused in
            // Clicking the terminal is another way of asking for it, so the binding has
            // to hear about focus the view took on its own.
            if isFocused != focused { isFocused = focused }
        }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.apply(onText: onText, onBytes: onBytes, onClear: onClear)
        view.wantsFocus = isFocused
        // Only ever claim focus, never clear it: handing it back to nobody would leave
        // the window with no first responder at all, and typing would go nowhere.
        // Whatever the user moves to next takes it from here on its own.
        if isFocused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class KeyView: NSView {
        private var onText: ((String) -> Void)?
        private var onBytes: ((Data) -> Void)?
        private var onClear: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        // What the app wants, as opposed to what AppKit currently has. The two come
        // apart whenever the window stops being the key one.
        var wantsFocus = false

        func apply(onText: @escaping (String) -> Void,
                   onBytes: @escaping (Data) -> Void,
                   onClear: @escaping () -> Void) {
            self.onText = onText
            self.onBytes = onBytes
            self.onClear = onClear
        }

        override var acceptsFirstResponder: Bool { true }

        // Switching to another app and back must not cost the terminal its keyboard.
        // AppKit does not restore a first responder on its own here, so the claim is
        // made again as soon as the window is key.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func windowBecameKey() {
            guard wantsFocus, window?.firstResponder !== self else { return }
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            needsDisplay = true
            onFocusChange?(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            needsDisplay = true
            // A window merely losing key status is not the user moving focus elsewhere,
            // so the terminal keeps its claim and takes the keyboard back on return.
            if window?.isKeyWindow == true { onFocusChange?(false) }
            return true
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // Clicking anywhere in the terminal starts typing into it.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        // A focused terminal draws a faint ring, so it is clear where typing goes.
        override func draw(_ dirtyRect: NSRect) {
            guard window?.firstResponder === self else { return }
            Theme.focusRing.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags

            if flags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "k": onClear?()
                case "v": paste()
                default: super.keyDown(with: event)
                }
                return
            }

            // Ctrl-C, ctrl-D and friends: the letter's position in the alphabet is the
            // control code the tty expects.
            if flags.contains(.control), let character = event.charactersIgnoringModifiers?.lowercased().first {
                // Backtick belongs to the app, which uses it to move focus.
                if character == "`" { super.keyDown(with: event); return }
                if let ascii = character.asciiValue, ascii >= 0x61, ascii <= 0x7A {
                    onBytes?(Data([ascii - 0x60]))
                    return
                }
            }

            if let special = Self.specialKey(event) {
                onBytes?(Data(special.utf8))
                return
            }

            guard let characters = event.characters, !characters.isEmpty else { return }
            onText?(characters)
        }

        // Return sends a carriage return, not a newline: a tty in canonical mode is
        // what turns that into "run this line".
        private static func specialKey(_ event: NSEvent) -> String? {
            let applicationCursor = event.modifierFlags.contains(.option) ? "\u{1B}" : ""
            switch Int(event.keyCode) {
            case 36, 76: return "\r"
            case 51: return "\u{7F}"          // delete
            case 117: return "\u{1B}[3~"      // forward delete
            case 48: return "\t"
            case 53: return "\u{1B}"          // escape
            case 126: return applicationCursor + "\u{1B}[A"
            case 125: return applicationCursor + "\u{1B}[B"
            case 124: return applicationCursor + "\u{1B}[C"
            case 123: return applicationCursor + "\u{1B}[D"
            case 115: return "\u{1B}[H"       // home
            case 119: return "\u{1B}[F"       // end
            case 116: return "\u{1B}[5~"      // page up
            case 121: return "\u{1B}[6~"      // page down
            default: return nil
            }
        }

        private func paste() {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            onText?(text)
        }
    }
}
