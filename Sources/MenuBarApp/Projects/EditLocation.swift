import Foundation

// Where an edit landed in the file it changed.
//
// Claude Code sends the strings it swapped and nothing about the file around them, so
// the only place the line number exists is the file itself. It is read the moment the
// call reports in, when what is on disk is still exactly what the call wrote, and kept
// with the call from then on. Codex needs none of this: its edits arrive as unified
// diffs, which carry their own numbering.
enum EditLocation {

    // The search runs on the turn's own thread while the stream is being read, so it has
    // to stay cheap. Every file an agent edits by hand fits well inside this; anything
    // larger is a build artefact or a data dump, not something worth a gutter.
    static let fileSizeLimit = 2 << 20

    // The line the call's new text begins on, counted from 1. Nil when the file cannot
    // be read, or when what the call wrote is not in it - a failed edit, or a file
    // something else has since rewritten.
    static func startLine(name: String, input: String) -> Int? {
        guard name == "Edit" || name == "Write" else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)),
              let fields = object as? [String: Any],
              let path = fields["file_path"] as? String,
              // Codex sends a unified diff, which is numbered already.
              fields["diff"] == nil
        else { return nil }
        // A written file is the whole file, so it starts where every file starts.
        if name == "Write" { return 1 }
        guard let needle = fields["new_string"] as? String, !needle.isEmpty else { return nil }
        return startLine(of: needle, inFileAt: path)
    }

    // Counting newlines over the raw bytes keeps a large file out of memory as a String,
    // and lines are separated by the same byte in every encoding the agents write.
    static func startLine(of needle: String, inFileAt path: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= fileSizeLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let found = data.firstRange(of: Data(needle.utf8))
        else { return nil }
        return 1 + data[data.startIndex..<found.lowerBound].count { $0 == 0x0A }
    }
}
