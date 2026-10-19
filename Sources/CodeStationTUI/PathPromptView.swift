import Foundation
import TerminalKit
import TerminalTranscript

// The terminal's folder picker: a line to type a path on, shown over everything else
// when the core asks the host for a folder, or to add a project. Tab completes a folder
// name, as a shell does, listing the folders that match when there are several. Enter
// answers with what was typed, Esc cancels. The host resolves `~` and relative paths and
// refuses what is not a folder; why it refused shows under the field.
struct PathPromptView {
    let prompt: String
    let message: String
    let startingAt: String?
    var field = ComposerView()
    // Why the path chosen last was refused, until the next key.
    var notice: String?
    // The folders the last Tab found, when it found more than one.
    private(set) var candidates: [String] = []
    // Whether Tab offers files as well as folders, for a path that names a file, such
    // as an attachment.
    var files = false
    // What Enter does, said in the footer.
    var chooseLabel = "choose"

    init(prompt: String, message: String, startingAt: String?, text: String = "", notice: String? = nil) {
        self.prompt = prompt
        self.message = message
        self.startingAt = startingAt
        self.notice = notice
        field.replace(with: text)
    }

    enum Outcome { case edited, choose, cancel, ignored }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        if key != .tab([]) { candidates = [] }
        switch key {
        case .escape: return .cancel
        // One line only: a newline key or a pasted break is not part of a path.
        case .enter([]): return .choose
        case .enter, .char("j", .ctrl): return .ignored
        case .tab([]):
            let completion = PathCompletion.complete(field.string, startingAt: startingAt, files: files)
            field.replace(with: completion.text)
            candidates = completion.candidates
            if completion.candidates.isEmpty, !completion.completed {
                notice = files ? "No file or folder starts with that." : "No folder starts with that."
            }
            return .edited
        case .paste(let text):
            return field.handle(.paste(text.split(whereSeparator: \.isNewline).joined())) == .ignored
                ? .ignored : .edited
        default:
            return field.handle(key) == .ignored ? .ignored : .edited
        }
    }

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        let title = prompt.isEmpty ? "Choose a folder" : prompt
        var lines = [Style.bold + TerminalColumns.fit(" " + title, to: width) + Style.reset, ""]
        if !message.isEmpty { lines += TranscriptRenderer.wrap(message, width: width - 2).map { " " + $0 } + [""] }
        if let startingAt {
            lines.append(Style.dim + TerminalColumns.fit(" A relative path starts in \(startingAt)", to: width)
                         + Style.reset)
        }
        lines.append(Style.dim + " ~ is your home folder." + Style.reset)
        lines.append("")
        let (field, at) = field.layout(width: width - 1)
        let top = lines.count
        lines += field.map { " " + $0 }
        if let notice {
            lines.append(Style.yellow + TerminalColumns.fit(" " + notice, to: width) + Style.reset)
        }
        let rows = max(size.rows, lines.count + 1)
        // The folders that match, as many as fit, in columns of their own.
        if !candidates.isEmpty {
            lines.append("")
            let room = max(rows - lines.count - 1, 0)
            let shown = candidates.count > room ? Array(candidates.prefix(max(room - 1, 0))) : candidates
            lines += shown.map { Style.dim + TerminalColumns.fit("   " + $0, to: width) + Style.reset }
            if shown.count < candidates.count, room > 0 {
                lines.append(Style.dim + "   +\(candidates.count - shown.count) more" + Style.reset)
            }
        }
        lines += Array(repeating: "", count: max(rows - lines.count - 1, 0))
        lines.append(Style.dim + TerminalColumns.fit(" enter \(chooseLabel) · tab complete · esc cancel", to: width) + Style.reset)
        return (lines, Screen.Cursor(row: top + at.row, col: at.col + 1))
    }
}

// Completing a typed folder path as a shell does: the last part of the path is finished
// to the one folder it starts, or to as much as the folders it starts share. Files are
// not offered unless asked for (a task's file input), and hidden ones only once the part
// typed starts with a dot. Read on
// this machine, which is the host's in the supported case (a terminal beside its host).
enum PathCompletion {
    struct Result: Equatable {
        // The path, completed as far as it goes.
        var text: String
        // The matching folders, each with a slash, when more than one matches.
        var candidates: [String] = []
        // Whether one folder matched and the path now names it.
        var completed = false
    }

    // `files` offers files as well as folders. A folder still gets its slash, so Tab
    // carries on into it; a file is finished as it is.
    static func complete(_ typed: String, startingAt base: String?, files: Bool = false,
                         fileManager: FileManager = .default) -> Result {
        let slash = typed.lastIndex(of: "/")
        let directoryPart = slash.map { String(typed[...$0]) } ?? ""
        let partial = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        // A bare `~` is the home folder, finished with its slash.
        if typed == "~" { return Result(text: "~/", completed: true) }

        let expanded = (directoryPart as NSString).expandingTildeInPath
        let directory: String
        if expanded.hasPrefix("/") {
            directory = expanded
        } else {
            let start = base ?? fileManager.currentDirectoryPath
            directory = expanded.isEmpty ? start : (start as NSString).appendingPathComponent(expanded)
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return Result(text: typed) }
        let folders = names.filter { name in
            guard partial.hasPrefix(".") || !name.hasPrefix(".") else { return false }
            guard name.lowercased().hasPrefix(partial.lowercased()) else { return false }
            var isFolder: ObjCBool = false
            let path = (directory as NSString).appendingPathComponent(name)
            return fileManager.fileExists(atPath: path, isDirectory: &isFolder) && (files || isFolder.boolValue)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let slashed = { (name: String) -> String in
            var isFolder: ObjCBool = false
            let path = (directory as NSString).appendingPathComponent(name)
            return fileManager.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? name + "/" : name
        }

        switch folders.count {
        case 0:
            return Result(text: typed)
        case 1:
            return Result(text: directoryPart + slashed(folders[0]), completed: true)
        default:
            let shared = folders.dropFirst().reduce(folders[0]) { common, name in
                String(zip(common, name).prefix { $0.0 == $0.1 }.map(\.0))
            }
            let text = shared.count > partial.count ? directoryPart + shared : typed
            return Result(text: text, candidates: folders.map(slashed))
        }
    }
}
