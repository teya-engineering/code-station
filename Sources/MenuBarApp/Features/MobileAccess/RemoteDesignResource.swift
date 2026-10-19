import Foundation
import CodeStationCore

// Serving a design file to the phone builds a LANResource, which belongs to the GUI's
// web socket server, so this half of RemoteDesignArtifacts stays here.
extension RemoteDesignArtifacts {
    static func resource(_ path: String, in directory: URL) -> LANResource? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let relative = url.path.pathRelative(to: root.path), relative == path,
              let type = contentTypes[url.pathExtension.lowercased()],
              let files = DesignArtifactRevision.read(root),
              files.files.contains(where: { $0.path == path && $0.size <= 10 * 1024 * 1024 }),
              url.pathExtension.lowercased() != "html"
                || DesignManifest.read(from: root).screens.contains(where: { $0.path == path }),
              let data = try? Data(contentsOf: url) else { return nil }
        return LANResource(data: data, contentType: type)
    }
}
