import Foundation

// One hole in a task's prompt, and how the run sheet should ask for it. Everything past
// the name is dressing: a placeholder with nothing saved for it is still asked for, as a
// required line of text.
struct TaskInput: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text, longText, choice, path, toggle

        var title: String {
            switch self {
            case .text: "Text"
            case .longText: "Long text"
            case .choice: "Choice"
            case .path: "File or folder"
            case .toggle: "Toggle"
            }
        }
    }

    // Matches the placeholder in the prompt. Two spellings that differ only in case or in
    // spacing are the same hole, so this is compared through `TaskTemplate.key`.
    var name: String
    var label: String?
    var kind: Kind = .text
    // The text this input can put in the prompt: the list to pick from for a choice, and
    // the on and off text for a toggle.
    var options: [String] = []
    var hint: String?
    var defaultValue: String?
    var required = true

    init(name: String, label: String? = nil, kind: Kind = .text, options: [String] = [],
         hint: String? = nil, defaultValue: String? = nil, required: Bool = true) {
        self.name = name
        self.label = label
        self.kind = kind
        self.options = options
        self.hint = hint
        self.defaultValue = defaultValue
        self.required = required
    }

    // Written whole today, but read leniently so a record saved before a field existed
    // still loads as the default rather than losing the whole task.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }

    // What the run sheet calls this field. A name written for the prompt reads well enough
    // as a label once its separators are spaces.
    var title: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        let words = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var onText: String { options.first ?? "yes" }
    var offText: String { options.count > 1 ? options[1] : "" }

    // A toggle always has an answer, so only the other kinds can be left unanswered.
    func isAnswered(_ value: String) -> Bool {
        kind == .toggle || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // What this input puts in the prompt. A toggle stores which way it is set rather than
    // the words it stands for, so the words can be reworded without stale runs.
    func substitution(for value: String) -> String {
        kind == .toggle ? (value == "on" ? onText : offText) : value
    }

    // What the value reads as in a run's summary line.
    func display(for value: String) -> String {
        kind == .toggle ? (value == "on" ? "on" : "off") : value
    }

    var startingValue: String {
        if let defaultValue, !defaultValue.isEmpty { return defaultValue }
        return kind == .toggle ? "off" : ""
    }
}

// A task's prompt is a template: anything inside double braces is a hole the run fills in.
// The prompt is the only place a hole is declared, so the list on the task screen and the
// fields on the run sheet are always exactly what the prompt asks for, and the two can
// never drift apart. A prompt without braces runs the way it always has.
enum TaskTemplate {
    // Names are matched without case and with runs of spaces collapsed, so `{{PR}}` and
    // `{{ pr }}` are one hole rather than two.
    static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // Every placeholder in the prompt, in the order it is first read. Later spellings of a
    // name it has already seen are the same hole and are not listed again.
    static func placeholders(in prompt: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let characters = Array(prompt)
        var i = 0
        while i + 1 < characters.count {
            guard characters[i] == "{", characters[i + 1] == "{" else {
                i += 1
                continue
            }
            // The scan stops at the first character a name cannot hold, so an unclosed
            // brace costs a few characters rather than the rest of the prompt.
            var end = i + 2
            while end < characters.count, isNameCharacter(characters[end]) { end += 1 }
            guard end + 1 < characters.count, characters[end] == "}", characters[end + 1] == "}",
                  let name = validName(String(characters[(i + 2)..<end])) else {
                i += 2
                continue
            }
            if seen.insert(key(name)).inserted { found.append(name) }
            i = end + 2
        }
        return found
    }

    // What the prompt asks for, dressed with whatever the task has saved about each hole.
    static func inputs(in spec: TaskSpec) -> [TaskInput] {
        let saved = Dictionary(spec.inputs.map { (key($0.name), $0) }) { _, last in last }
        return placeholders(in: spec.prompt).map { name in
            guard var input = saved[key(name)] else { return TaskInput(name: name) }
            // The prompt owns the spelling, so a placeholder retyped in another case
            // keeps everything saved for it.
            input.name = name
            return input
        }
    }

    // The saved inputs with one of them replaced. Entries whose placeholder is no longer
    // in the prompt are left alone: a hole being retyped or reworded should not throw away
    // how it was set up.
    static func saving(_ input: TaskInput, in spec: TaskSpec) -> [TaskInput] {
        var inputs = spec.inputs
        if let i = inputs.firstIndex(where: { key($0.name) == key(input.name) }) {
            inputs[i] = input
        } else {
            inputs.append(input)
        }
        return inputs
    }

    // The prompt a run actually sends. A line that asked only for something left blank is
    // left out, so an optional hole reads as a sentence that was never written rather than
    // a sentence with a gap in it.
    static func render(_ spec: TaskSpec, values: [String: String]) -> String {
        let inputs = inputs(in: spec)
        guard !inputs.isEmpty else { return spec.prompt }
        let text = Dictionary(uniqueKeysWithValues: inputs.map { input in
            (key(input.name), input.substitution(for: values[key(input.name)] ?? ""))
        })
        let lines = spec.prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let filled = substitute(String(line), text)
                guard !filled.asked || !filled.allBlank else { return nil }
                return filled.text
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // What a run was given, for the line under its name in the run list.
    static func summary(of values: [String: String], inputs: [TaskInput]) -> String {
        inputs.compactMap { input -> String? in
            let value = values[key(input.name)] ?? ""
            guard input.isAnswered(value) else { return nil }
            let shown = input.display(for: value)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !shown.isEmpty else { return nil }
            let cut = shown.count > 28 ? String(shown.prefix(28)) + "…" : shown
            return "\(input.title.lowercased()) \(cut)"
        }
        .joined(separator: " · ")
    }

    // MARK: - Scanning

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
            || character == " "
    }

    private static func validName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private static func substitute(_ line: String,
                                   _ text: [String: String]) -> (text: String, asked: Bool,
                                                                 allBlank: Bool) {
        var out = ""
        var asked = false
        var allBlank = true
        let characters = Array(line)
        var i = 0
        while i < characters.count {
            guard i + 1 < characters.count, characters[i] == "{", characters[i + 1] == "{" else {
                out.append(characters[i])
                i += 1
                continue
            }
            var end = i + 2
            while end < characters.count, isNameCharacter(characters[end]) { end += 1 }
            guard end + 1 < characters.count, characters[end] == "}", characters[end + 1] == "}",
                  let name = validName(String(characters[(i + 2)..<end])),
                  let value = text[key(name)] else {
                out.append(characters[i])
                i += 1
                continue
            }
            asked = true
            if !value.isEmpty { allBlank = false }
            out += value
            i = end + 2
        }
        // Taking a placeholder out at the end of a line leaves the space that ran up to it.
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return (out, asked, allBlank)
    }
}
