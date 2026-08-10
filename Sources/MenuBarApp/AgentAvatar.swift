import AppKit
import ImageIO
import SwiftUI

struct AgentAvatar: Identifiable {
    let url: URL
    let image: NSImage

    var id: URL { url }
}

enum AgentAvatarSelection {
    static func index(forTurn turn: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return max(0, turn) % count
    }
}

enum AgentAvatarFile {
    static let maxPixelSize = 512

    static func load(from url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func loadAll(from baseURL: URL) -> [AgentAvatar] {
        avatarURLs(for: baseURL).compactMap { url in
            load(from: url).map { AgentAvatar(url: url, image: $0) }
        }
    }

    static func importImages(from sourceURLs: [URL], to baseURL: URL) throws -> [AgentAvatar] {
        let prepared = try sourceURLs.map { try prepareImage(from: $0) }
        guard !prepared.isEmpty else { return [] }

        let files = FileManager.default
        let nextIndex = (avatarURLs(for: baseURL).compactMap {
            avatarIndex(for: $0, baseURL: baseURL)
        }.max() ?? 0) + 1
        let destinations = prepared.indices.map {
            avatarURL(index: nextIndex + $0, baseURL: baseURL)
        }

        try files.createDirectory(
            at: baseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var written: [URL] = []
        do {
            for (item, destination) in zip(prepared, destinations) {
                try item.data.write(to: destination, options: .atomic)
                written.append(destination)
            }
        } catch {
            for url in written {
                try? files.removeItem(at: url)
            }
            throw error
        }

        return zip(destinations, prepared).map {
            AgentAvatar(url: $0.0, image: $0.1.image)
        }
    }

    static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeAll(from baseURL: URL) throws {
        for url in avatarURLs(for: baseURL) {
            try remove(at: url)
        }
    }

    private static func prepareImage(from sourceURL: URL) throws -> (data: Data, image: NSImage) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else {
            throw AgentAvatarError.couldNotReadImage
        }

        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              let image = NSImage(data: data) else {
            throw AgentAvatarError.couldNotEncodeImage
        }
        return (data, image)
    }

    private static func avatarURLs(for baseURL: URL) -> [URL] {
        let files = FileManager.default
        guard let contents = try? files.contentsOfDirectory(
            at: baseURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return contents.compactMap { url in
            avatarIndex(for: url, baseURL: baseURL).map { ($0, url) }
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private static func avatarIndex(for url: URL, baseURL: URL) -> Int? {
        guard url.pathExtension.caseInsensitiveCompare(baseURL.pathExtension) == .orderedSame else {
            return nil
        }

        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let name = url.deletingPathExtension().lastPathComponent
        if name == baseName { return 1 }

        let prefix = "\(baseName)-"
        guard name.hasPrefix(prefix),
              let index = Int(name.dropFirst(prefix.count)),
              index > 1 else {
            return nil
        }
        return index
    }

    private static func avatarURL(index: Int, baseURL: URL) -> URL {
        guard index > 1 else { return baseURL }
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let filename = "\(baseName)-\(index).\(baseURL.pathExtension)"
        return baseURL.deletingLastPathComponent().appendingPathComponent(filename)
    }
}

enum AgentAvatarError: LocalizedError {
    case couldNotReadImage
    case couldNotEncodeImage

    var errorDescription: String? {
        switch self {
        case .couldNotReadImage:
            "The selected file is not an image the app can read."
        case .couldNotEncodeImage:
            "The selected image could not be prepared for use."
        }
    }
}

struct AgentAvatarView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.border))
            .accessibilityLabel("Bot image")
    }
}
