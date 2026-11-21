import Foundation

// Only published screens and browser assets may cross the pairing boundary. Resolving
// symlinks as well as dot segments keeps a design from exposing files outside its folder.
enum RemoteDesignArtifacts {
    static let contentTypes = [
        "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "woff": "font/woff", "woff2": "font/woff2",
    ]

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
