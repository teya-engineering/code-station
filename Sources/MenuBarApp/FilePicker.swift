import AppKit
import UniformTypeIdentifiers

// The file chooser is the one system surface the app keeps, since picking a path belongs
// to the Finder rather than to this window. Every panel is modal, so a caller only has
// to say what it is asking for.
@MainActor
enum FilePicker {
    // An empty list of types accepts any file.
    static func chooseFile(prompt: String, message: String, types: [UTType] = [],
                           directory: URL? = nil) -> URL? {
        open(files: true, multiple: false, types: types, directory: directory,
             prompt: prompt, message: message).first
    }

    static func chooseFiles(prompt: String, message: String, types: [UTType] = [],
                            directory: URL? = nil) -> [URL] {
        open(files: true, multiple: true, types: types, directory: directory,
             prompt: prompt, message: message)
    }

    static func chooseFolder(prompt: String, message: String, directory: URL? = nil) -> URL? {
        open(files: false, multiple: false, types: [], directory: directory,
             prompt: prompt, message: message).first
    }

    static func saveFile(suggestedName: String, prompt: String, message: String,
                         types: [UTType] = []) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // Empty unless the user confirmed, so callers never see a cancelled panel's leftovers.
    private static func open(files: Bool, multiple: Bool, types: [UTType], directory: URL?,
                             prompt: String, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = types
        panel.directoryURL = directory
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }
}
