import AppKit
import Foundation

// A record on disk of the CLI protocol events and what the app did about them.
//
// A turn that stops moving leaves nothing behind on screen: the process is alive, its
// pipes are open, the transcript is whatever streamed before the silence. Everything that
// would explain the gap - the last event type, a request the app could not answer, an exit
// nobody noticed - passes through here and nowhere else. Payloads stay in the transcript
// instead of being copied into a second file that may hold prompts, source code, or secrets.
enum SessionLog {
    // Bounds unexpected diagnostic text even though stream payloads are summarized.
    private static let maxLine = 2_000
    // Past this the file is rolled over. One spare generation is kept: a hang is noticed
    // within minutes or not at all, so older history buys nothing.
    private static let maxBytes = 5 << 20

    // Writes are ordered and off the main actor. Logging sits in the middle of the read
    // handler for every chunk of CLI output, so it must never wait on the disk.
    private static let queue = DispatchQueue(label: "\(AppPaths.bundleID).log", qos: .utility)

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter
    }()

    static var file: URL { AppPaths.logs.appendingPathComponent("sessions.log") }

    // One entry. `session` is the app's own session id, short enough at eight characters
    // to scan a file by eye and still tell two live turns apart.
    static func note(_ message: String, session: UUID? = nil) {
        let stamp = Date()
        let tag = session.map { String($0.uuidString.prefix(8)) } ?? "--------"
        let body = message.count > maxLine ? String(message.prefix(maxLine)) + "…" : message
        queue.async { append("\(clock.string(from: stamp)) [\(tag)] \(body)\n") }
    }

    // Where a stuck turn is usually explained, so it is worth having by hand rather than
    // hunting for the file.
    static func revealInFinder() {
        // Nothing has been logged yet on a fresh install, and Finder cannot reveal a file
        // that is not there.
        if !FileManager.default.fileExists(atPath: file.path) { note("log opened") }
        flush()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // Waits for everything already handed over to reach the disk. Writes are queued, so
    // anything that reads the file back has to come through here first.
    static func flush() { queue.sync {} }

    // MARK: - Reading it back

    // When the file last grew, which is all a reader needs to know whether to read again.
    static var lastWritten: Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
    }

    // The end of the log, which is the part worth reading: a turn that stopped is
    // explained by the last thing that happened, not by the first. The file rolls over at
    // five megabytes, so the whole of it is never worth holding in a view.
    static func tail(bytes: Int = 400_000) -> String {
        flush()
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }

        var text = String(decoding: data, as: UTF8.self)
        // Reading from a byte offset lands mid-line unless the file is short enough to
        // have been read whole, and half an entry reads as a corrupt one.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    // MARK: - Private

    // Always on the queue.
    private static func append(_ entry: String) {
        let files = FileManager.default
        let url = file

        if let size = (try? files.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            let previous = url.appendingPathExtension("1")
            try? files.removeItem(at: previous)
            try? files.moveItem(at: url, to: previous)
        }

        let data = Data(entry.utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
