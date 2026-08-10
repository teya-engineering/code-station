import AppKit
import ImageIO
import SwiftUI

struct AgentAvatar: Identifiable {
    let url: URL
    let image: NSImage
    let personality: AgentPersonality

    var id: URL { url }
}

enum AgentAvatarSelection {
    static func randomIndex(count: Int) -> Int? {
        guard count > 0 else { return nil }
        return Int.random(in: 0..<count)
    }

    static func index(forTurn turn: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return max(0, turn) % count
    }
}

enum AgentAvatarFile {
    static let maxPixelSize = 512
    static let maxCount = 5

    static func load(from url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func loadAll(from baseURL: URL) -> [AgentAvatar] {
        let personalities = loadPersonalities(from: baseURL)
        return avatarURLs(for: baseURL).compactMap { url in
            load(from: url).map {
                AgentAvatar(url: url,
                            image: $0,
                            personality: personalities[url.lastPathComponent] ?? .standard)
            }
        }
    }

    static func importImages(from sourceURLs: [URL],
                             to baseURL: URL,
                             personality: AgentPersonality = .standard) throws -> [AgentAvatar] {
        let prepared = try sourceURLs.map { try prepareImage(from: $0) }
        guard !prepared.isEmpty else { return [] }

        let existing = avatarURLs(for: baseURL)
        guard existing.count + prepared.count <= maxCount else {
            throw AgentAvatarError.tooManyAvatars
        }

        let files = FileManager.default
        let nextIndex = (existing.compactMap {
            avatarIndex(for: $0, baseURL: baseURL)
        }.max() ?? 0) + 1
        let destinations = prepared.indices.map {
            avatarURL(index: nextIndex + $0, baseURL: baseURL)
        }
        var personalities = loadPersonalities(from: baseURL)
        for destination in destinations {
            personalities[destination.lastPathComponent] = personality
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
            try savePersonalities(personalities, for: baseURL)
        } catch {
            for url in written {
                try? files.removeItem(at: url)
            }
            throw error
        }

        return zip(destinations, prepared).map {
            AgentAvatar(url: $0.0, image: $0.1.image, personality: personality)
        }
    }

    static func setPersonality(_ personality: AgentPersonality,
                               for avatarURL: URL,
                               baseURL: URL) throws {
        var personalities = loadPersonalities(from: baseURL)
        personalities[avatarURL.lastPathComponent] = personality
        try savePersonalities(personalities, for: baseURL)
    }

    static func remove(at url: URL, from baseURL: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
        var personalities = loadPersonalities(from: baseURL)
        personalities[url.lastPathComponent] = nil
        try savePersonalities(personalities, for: baseURL)
    }

    static func removeAll(from baseURL: URL) throws {
        for url in avatarURLs(for: baseURL) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let metadataURL = personalityURL(for: baseURL)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
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

    private static func loadPersonalities(from baseURL: URL) -> [String: AgentPersonality] {
        guard let data = try? Data(contentsOf: personalityURL(for: baseURL)),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        // Entries saved by builds with personalities that no longer exist fall back
        // to the default instead of discarding everyone's assignments.
        return stored.compactMapValues(AgentPersonality.init(rawValue:))
    }

    private static func savePersonalities(_ personalities: [String: AgentPersonality],
                                          for baseURL: URL) throws {
        let url = personalityURL(for: baseURL)
        if personalities.isEmpty {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(personalities)
        try data.write(to: url, options: .atomic)
    }

    private static func personalityURL(for baseURL: URL) -> URL {
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        return baseURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-personalities.json")
    }
}

enum AgentAvatarError: LocalizedError {
    case couldNotReadImage
    case couldNotEncodeImage
    case tooManyAvatars

    var errorDescription: String? {
        switch self {
        case .couldNotReadImage:
            "The selected file is not an image the app can read."
        case .couldNotEncodeImage:
            "The selected image could not be prepared for use."
        case .tooManyAvatars:
            "The app supports up to \(AgentAvatarFile.maxCount) bots. Remove one to add another."
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
            .accessibilityLabel("Bot")
    }
}
