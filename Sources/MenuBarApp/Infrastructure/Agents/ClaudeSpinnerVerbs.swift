import Foundation

// The words Claude Code shows on its spinner, as the person set them with `spinnerVerbs`.
// The app draws its own working row rather than Claude's spinner, so without this a
// Claude session in the app speaks in the app's words, not the ones chosen for the CLI.
enum ClaudeSpinnerVerbs {
    // `replace` uses only the person's verbs; anything else adds them to the words given,
    // which is what Claude does when no mode is set. The nearest file that sets the verbs
    // wins: the checkout's local settings, then its shared ones, then the person's own.
    static func applied(to words: [String], lead: String?,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let base = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var files = [base.appendingPathComponent("settings.json")]
        if let lead {
            let root = URL(fileURLWithPath: lead)
            files += [root.appendingPathComponent(".claude/settings.json"),
                      root.appendingPathComponent(".claude/settings.local.json")]
        }
        guard let setting = files.reversed().lazy.compactMap(spinnerVerbs(at:)).first else { return words }
        let verbs = setting.verbs.map(\.trimmed).filter { !$0.isEmpty }
        guard !verbs.isEmpty else { return words }
        if setting.mode == "replace" { return verbs }
        return words + verbs.filter { !words.contains($0) }
    }

    private struct Settings: Decodable {
        struct SpinnerVerbs: Decodable {
            var mode: String?
            var verbs: [String]
        }

        var spinnerVerbs: SpinnerVerbs?
    }

    private static func spinnerVerbs(at url: URL) -> Settings.SpinnerVerbs? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Settings.self, from: data))?.spinnerVerbs
    }
}
