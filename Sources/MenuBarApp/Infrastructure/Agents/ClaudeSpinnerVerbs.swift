import Foundation

// The words Claude Code shows on its spinner, as the person set them with `spinnerVerbs`.
// The app draws its own working row rather than Claude's spinner, so without this a
// Claude session in the app speaks in the app's words, not the ones chosen for the CLI.
struct ClaudeSpinnerVerbs: Equatable, Sendable {
    enum Mode: String, Decodable, Sendable {
        case append
        case replace
    }

    let mode: Mode
    let verbs: [String]

    // Settled the way Claude settles its settings: the nearest file's mode wins, and the
    // verbs from every file are joined, each one once. Claude skips a file it cannot
    // read or whose setting has no valid mode or list, so the files below it still count.
    // Foundation reads a trailing comma that Claude would reject, which only matters for
    // a file Claude already ignores.
    static func load(configDirectory: URL, lead: String?) -> ClaudeSpinnerVerbs? {
        var mode: Mode?
        var verbs: [String] = []
        let files = AgentCommands.claudeSettingsFiles(base: configDirectory,
                                                      lead: lead.map { URL(fileURLWithPath: $0) })
        for file in files {
            guard let setting = setting(at: file) else { continue }
            mode = setting.mode
            verbs += setting.verbs.filter { !verbs.contains($0) }
        }
        return mode.map { ClaudeSpinnerVerbs(mode: $0, verbs: verbs) }
    }

    // A replace with nothing usable in it leaves the words alone, as Claude falls back to
    // its own list then, and a row with nothing to say would look broken.
    func applied(to words: [String]) -> [String] {
        let verbs = verbs.map(\.trimmed).filter { !$0.isEmpty }
        if mode == .replace { return verbs.isEmpty ? words : verbs }
        return words + verbs.filter { !words.contains($0) }
    }

    private struct Settings: Decodable {
        struct SpinnerVerbs: Decodable {
            let mode: Mode
            let verbs: [String]
        }

        let spinnerVerbs: SpinnerVerbs?
    }

    private static func setting(at url: URL) -> Settings.SpinnerVerbs? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Settings.self, from: data))?.spinnerVerbs
    }
}
