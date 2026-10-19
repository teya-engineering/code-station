import AppKit
import SwiftUI
import CodeStationCore

struct DictationFeedback: View {
    let dictation: Dictation
    let sessionID: UUID
    let draft: Binding<SessionComposerStore.Draft>
    let notice: Dictation.Notice?

    var body: some View {
        if let notice {
            DictationNoticeRow(
                notice: notice,
                languageName: dictation.languageName,
                inputName: dictation.inputName,
                unsure: dictation.review(sessionID)?.unsure ?? [],
                languageMenu: languageMenu,
                inputMenu: inputMenu,
                wordMenu: wordMenu,
                openSettings: { dictation.openPrivacySettings($0) },
                undo: { dictation.undo() })
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    func wordMenu(_ word: UnsureWord) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(word.heard, checked: true, subtitle: "What Code Station heard") {
                dictation.choose(nil, for: word, in: sessionID, draft: draft)
            }
        ]
        entries += word.alternatives.map { alternative in
            .item(alternative) { dictation.choose(alternative, for: word, in: sessionID, draft: draft) }
        }
        entries.append(.separator)
        entries.append(.item("Keep and stop asking") {
            dictation.choose(nil, for: word, in: sessionID, draft: draft)
        })
        return entries
    }

    private func inputMenu() -> [MenuEntry] {
        AudioInputs.all().map { input in
            .item(input.name, checked: input.name == dictation.inputName,
                  detail: input.name == dictation.inputName ? "no sound" : nil) {
                dictation.chooseInput(input)
            }
        }
    }

    private func languageMenu() -> [MenuEntry] {
        let current = dictation.language.identifier(.bcp47)
        let items = dictation.languages.map { locale in
            MenuItem(label: DictationLanguages.name(of: locale),
                     checked: locale.identifier(.bcp47) == current,
                     handler: { dictation.chooseLanguage(locale) })
        }
        return [.searchable(items, prompt: "Find a language", noResults: "No language matches")]
    }
}

// The microphone at the end of the prompt box. Idle it is a plain glyph; while the app
// listens it widens into a lime pill with a level meter and a clock. It grows in width
// rather than scaling, since the button holds views AppKit lays out itself.
struct DictationMicButton: View {
    let live: Bool
    let preparing: Bool
    let blocked: Bool
    let level: Float
    let startedAt: Date?
    let download: Double?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if live {
                    DictationLevelBars(level: level)
                    DictationClock(startedAt: startedAt)
                } else {
                    Image(systemName: blocked ? "mic.slash" : "mic")
                        .font(.system(size: 13, weight: .regular))
                        .opacity(preparing ? 0.35 : 1)
                        .overlay {
                            if preparing { DownloadRing(fraction: download ?? 0) }
                        }
                }
            }
            .foregroundStyle(live ? Theme.listenOnFill
                             : blocked ? Theme.warningText
                             : hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, live ? 8 : 0)
            .frame(minWidth: live ? 74 : 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(live ? Theme.listenFill : hovering && isEnabled ? Theme.field : .clear))
            .overlay {
                if live {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.listenOnFill.opacity(0.18))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.control, value: live)
        .appTooltip(live ? "" : preparing ? "Getting dictation ready" : "Dictate (⇧⌘D)")
        .accessibilityLabel(live ? "Stop dictating" : "Dictate")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(live ? "On" : "Off")
    }
}

// Five bars that follow the input level, so it is plain the microphone is hearing
// something. With motion turned down they hold still.
private struct DictationLevelBars: View {
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                // The middle bar moves most, so the row reads as one shape.
                let shape = 1 - abs(Double(index) - 2) / 5
                let height = reduceMotion ? 6 : 3 + 11 * min(1, Double(level) * shape * 1.4)
                Capsule()
                    .frame(width: 2, height: height)
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private struct DictationClock: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(startedAt ?? context.date)))
                .font(.mono(11, .semibold))
                .monospacedDigit()
        }
        .accessibilityHidden(true)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

private struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.field, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Theme.listenInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// The row above the prompt box that says what the microphone is doing and what can be
// done next. Every state that stops dictation names its way out.
struct DictationNoticeRow: View {
    let notice: Dictation.Notice
    let languageName: String
    let inputName: String?
    let unsure: [UnsureWord]
    let languageMenu: () -> [MenuEntry]
    let inputMenu: () -> [MenuEntry]
    let wordMenu: (UnsureWord) -> [MenuEntry]
    let openSettings: (DictationFailure) -> Void
    let undo: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        .foregroundStyle(ink)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    private var background: Color {
        switch notice {
        case .listening, .preparing: Theme.listenTint
        case .blocked(.microphoneBlocked), .blocked(.speechBlocked), .failed: Theme.warningBackground
        default: Theme.sunken
        }
    }

    private var ink: Color {
        switch notice {
        case .listening, .preparing: Theme.listenInk
        case .blocked(.microphoneBlocked), .blocked(.speechBlocked), .failed: Theme.warningText
        default: .secondary
        }
    }

    @ViewBuilder private var content: some View {
        switch notice {
        case .listening:
            HStack(spacing: 6) {
                BreathingDot(reduceMotion: reduceMotion)
                Text("Listening in \(languageName)").fontWeight(.semibold)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                keyHint("return", "Stop")
                keyHint("esc", "Throw away")
                Text("Say “new line” or “full stop”")
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        case .preparing(let download):
            (Text("Getting dictation ready for \(languageName). ").fontWeight(.semibold)
                + Text("It runs on this Mac, so this download happens once."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Meter(fraction: download?.fraction ?? 0, colour: Theme.listenInk, height: 4)
                .frame(width: 140)
            Text(Self.progress(download))
                .font(.mono(11, .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            languageButton
        case .nothingHeard(let input):
            Image(systemName: "exclamationmark.triangle")
            (Text("Nothing is coming through from ") + Text(input).fontWeight(.semibold)
                + Text(". Check it is not muted, or pick another."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(inputName ?? input).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .surface(Theme.card, cornerRadius: 7)
            .appMenu(edge: .top, inputMenu)
            .accessibilityLabel("Listen through \(inputName ?? input)")
        case .blocked(let failure):
            blocked(failure)
        case .waitingForPermission:
            (Text("Waiting for you to allow Code Station in ")
                + Text("Privacy & Security > Microphone").fontWeight(.semibold) + Text("…"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .allowed:
            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
            (Text("Microphone allowed. ").fontWeight(.semibold)
                + Text("Click the mic or press ⇧⌘D to start."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unsure(let count, let seconds):
            (Text(count == 1 ? "1 word to check. " : "\(count) words to check. ").fontWeight(.semibold)
                + Text("Dotted words are ones Code Station wasn't sure of. Click one for other options."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The same choices as clicking the word, here so they can be reached from
            // the keyboard.
            ForEach(Array(unsure.prefix(3).enumerated()), id: \.offset) { _, word in
                Text(word.heard)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .underline(pattern: .dot, color: Theme.listenEdge)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .surface(Theme.card, cornerRadius: 7)
                    .appMenu(edge: .top) { wordMenu(word) }
                    .accessibilityLabel("Check “\(word.heard)”")
            }
            Text("\(DictationClock.format(TimeInterval(seconds))) spoken")
                .font(.mono(11, .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        case .thrownAway:
            Text("Threw away that take.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: undo) {
                Text("Undo")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func blocked(_ failure: DictationFailure) -> some View {
        switch failure {
        case .microphoneBlocked, .speechBlocked:
            let what = failure == .speechBlocked ? "speech recognition" : "the microphone"
            Image(systemName: "exclamationmark.triangle")
            (Text("Code Station isn't allowed to use \(what). ").fontWeight(.semibold)
                + Text("Turn it on in System Settings, then click the mic again."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ActionButton(title: "Open Privacy Settings", tone: .outlined, height: 24, size: 12) {
                openSettings(failure)
            }
        case .modelMissing:
            Image(systemName: "exclamationmark.triangle")
            (Text("Dictation in \(languageName) needs its on-device model. ").fontWeight(.semibold)
                + Text("Add it in System Settings > Keyboard > Dictation, then click the mic again."))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            languageButton
        case .languageUnsupported:
            Image(systemName: "exclamationmark.triangle")
            Text("Dictation isn't available in \(languageName) on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            languageButton
        case .engine(let message):
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var languageButton: some View {
        Text("Change language")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .appMenu(edge: .top, languageMenu)
    }

    private func keyHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key: key)
            Text(title)
        }
        .fixedSize()
    }

    static func progress(_ download: DictationDownload?) -> String {
        guard let download else { return "Starting…" }
        if let done = download.completedBytes, let total = download.totalBytes {
            let megabytes = { (bytes: Int64) in Int((Double(bytes) / 1_000_000).rounded()) }
            return "\(megabytes(done)) of \(megabytes(total)) MB"
        }
        return "\(Int((download.fraction * 100).rounded()))%"
    }
}

private struct BreathingDot: View {
    let reduceMotion: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.listenInk)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// Return and escape while the app is listening. A local monitor sees them before the
// window's own shortcuts, which is what keeps escape from also stopping a running turn
// and return from ever reaching send.
@MainActor
final class DictationKeys {
    weak var anchor: NSView?
    private var token: Any?

    func start(stop: @escaping () -> Void, throwAway: @escaping () -> Void) {
        self.stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let window = self?.anchor?.window, event.window === window,
                      WindowKeyMonitor.routes(to: window, frontmost: WindowKeyMonitor.frontmostWindow),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                else { return false }
                switch event.keyCode {
                case 36, 76: stop()
                case 53: throwAway()
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

struct DictationKeysAnchor: NSViewRepresentable {
    let keys: DictationKeys

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        keys.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { keys.anchor = view }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
