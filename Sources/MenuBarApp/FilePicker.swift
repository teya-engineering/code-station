import AppKit
import UniformTypeIdentifiers

// The file chooser is the one system surface the app keeps, since picking a path belongs
// to the Finder rather than to this window. Every panel is modal and picks a single
// item, so a caller only has to say what it is asking for.
@MainActor
enum FilePicker {
    // An empty list of types accepts any file.
    static func chooseFile(prompt: String, message: String, types: [UTType] = [],
                           directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        panel.directoryURL = directory
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(prompt: String, message: String, directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
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
}
