import Foundation

enum DesignMaterialExporter {
    enum ExportError: LocalizedError, Equatable {
        case noMaterials
        case couldNotReadMaterials(String)
        case couldNotCreateArchive(String)
        case destinationInsideMaterials

        var errorDescription: String? {
            switch self {
            case .noMaterials:
                "There are no Design materials to export yet."
            case .couldNotReadMaterials(let detail):
                "The Design materials could not be read: \(detail)"
            case .couldNotCreateArchive(let detail):
                "The ZIP file could not be created: \(detail)"
            case .destinationInsideMaterials:
                "Choose a location outside the Design materials folder."
            }
        }
    }

    static func suggestedFileName(projectName: String, sessionTitle: String) -> String {
        let rawName = "\(projectName) - \(sessionTitle) - Design materials"
        let invalid = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\?%*|\"<>:"))
        let safeName = rawName.unicodeScalars
            .map { invalid.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let stem = String(safeName.prefix(180)).trimmed
        return "\(stem.isEmpty ? "Design materials" : stem).zip"
    }

    static func export(materialsAt source: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExportError.noMaterials
        }

        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: source.path)
        } catch {
            throw ExportError.couldNotReadMaterials(error.localizedDescription)
        }
        guard !entries.isEmpty else { throw ExportError.noMaterials }

        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard !destinationPath.hasPrefix(sourcePath + "/") else {
            throw ExportError.destinationInsideMaterials
        }

        let output: CommandRunner.Output
        do {
            output = try await CommandRunner.run(
                executable: "/usr/bin/ditto",
                arguments: [
                    "-c", "-k",
                    "--norsrc", "--noextattr", "--noqtn", "--noacl",
                    source.path, destination.path,
                ],
                timeout: .seconds(300))
        } catch {
            throw ExportError.couldNotCreateArchive(error.localizedDescription)
        }
        guard output.succeeded else {
            let detail = output.errorOutput.trimmed
            throw ExportError.couldNotCreateArchive(
                detail.isEmpty ? "ditto exited with status \(output.status)." : detail)
        }
    }
}
