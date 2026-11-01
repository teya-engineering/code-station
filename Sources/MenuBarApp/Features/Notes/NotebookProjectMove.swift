import Foundation

enum NotebookProjectMove {
    static func destination(root: URL, relativePath: String) throws -> URL {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path.components(separatedBy: "/")
        guard !path.hasPrefix("/"), path.lowercased().hasSuffix(".md"),
              !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NotebookError("Use a relative path ending in .md, such as docs/notes/idea.md.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NotebookError("This project folder is no longer available.")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path) {
                guard [.typeDirectory, .typeSymbolicLink].contains(attributes[.type] as? FileAttributeType) else {
                    throw NotebookError("A parent in this path is a file. Choose another destination.")
                }
                parent = parent.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
                    throw NotebookError("The destination must stay inside the selected project, including linked folders.")
                }
            }
        }
        let destination = parent.appendingPathComponent(components.last!)
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw NotebookError("A file already exists at this path. Choose another name.")
        }
        return destination
    }
}
