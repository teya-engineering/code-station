import AppKit
import ImageIO
import SwiftUI

struct AgentAvatar: Identifiable {
    let url: URL
    let image: NSImage
    let personality: AgentPersonality
    let usesStockArtwork: Bool

    var id: URL { url }

    @MainActor
    func displayImage(for sessionID: UUID?) -> NSImage {
        guard usesStockArtwork else { return image }
        guard let sessionID else { return AgentAvatarArt.image(for: personality) }
        return AgentAvatarArt.sessionImage(
            for: sessionID,
            avatarName: url.lastPathComponent) ?? image
    }
}

enum AgentAvatarSelection {
    static let defaultName = AgentPersonality.standard.rawValue

    static func resolvedName(_ preferredName: String?, availableNames: [String]) -> String {
        if let preferredName, availableNames.contains(preferredName) {
            return preferredName
        }
        return defaultName
    }

    @MainActor
    static func avatar(named name: String?, from avatars: [AgentAvatar]) -> AgentAvatar {
        if let name, let selected = avatars.first(where: {
            $0.url.lastPathComponent == name
        }) {
            return selected
        }

        // Missing, removed, and old opt-out choices all upgrade to the built-in bot
        // without rewriting saved sessions.
        return builtInDefault
    }

    @MainActor
    private static var builtInDefault: AgentAvatar {
        AgentAvatar(
            url: URL(fileURLWithPath: "/.code-station/bots/\(defaultName)"),
            image: AgentAvatarArt.image(for: .standard),
            personality: .standard,
            usesStockArtwork: true)
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
                            personality: personalities[url.lastPathComponent] ?? .standard,
                            usesStockArtwork: AgentAvatarArt.isStock(at: url))
            }
        }
    }

    static func importImages(from sourceURLs: [URL],
                             to baseURL: URL,
                             personality: AgentPersonality = .standard) throws -> [AgentAvatar] {
        let prepared = try sourceURLs.map { try prepareImage(from: $0) }
        guard !prepared.isEmpty else { return [] }
        return try store(prepared, to: baseURL, personality: personality)
    }

    private static func store(_ prepared: [(data: Data, image: NSImage)],
                              to baseURL: URL,
                              personality: AgentPersonality) throws -> [AgentAvatar] {
        let existing = avatarURLs(for: baseURL)
        guard existing.count + prepared.count <= maxCount else {
            throw AgentAvatarError.tooManyAvatars
        }

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

        var written: [URL] = []
        do {
            for (item, destination) in zip(prepared, destinations) {
                try PersistentFile.write(item.data, to: destination)
                written.append(destination)
            }
            try savePersonalities(personalities, for: baseURL)
        } catch {
            for url in written {
                try? PersistentFile.removeIfPresent(url)
            }
            throw error
        }

        return zip(destinations, prepared).map {
            AgentAvatar(url: $0.0, image: $0.1.image, personality: personality,
                        usesStockArtwork: AgentAvatarArt.isStock(data: $0.1.data))
        }
    }

    static func addStockPicture(personality: AgentPersonality,
                                to baseURL: URL) throws -> [AgentAvatar] {
        let data = try AgentAvatarArt.pngData(for: personality)
        guard let image = NSImage(data: data) else {
            throw AgentAvatarError.couldNotReadImage
        }
        return try store([(data, image)], to: baseURL, personality: personality)
    }

    static func setPersonality(_ personality: AgentPersonality,
                               for avatar: AgentAvatar,
                               baseURL: URL) throws -> AgentAvatar {
        // Ours is the personality made visible; a photo is the user's and stays.
        var picture = avatar.image
        if avatar.usesStockArtwork {
            let data = try AgentAvatarArt.pngData(for: personality)
            try PersistentFile.write(data, to: avatar.url)
            picture = NSImage(data: data) ?? picture
        }

        var personalities = loadPersonalities(from: baseURL)
        personalities[avatar.url.lastPathComponent] = personality
        try savePersonalities(personalities, for: baseURL)
        return AgentAvatar(url: avatar.url, image: picture, personality: personality,
                           usesStockArtwork: avatar.usesStockArtwork)
    }

    static func remove(at url: URL, from baseURL: URL) throws {
        try PersistentFile.removeIfPresent(url)
        var personalities = loadPersonalities(from: baseURL)
        personalities[url.lastPathComponent] = nil
        try savePersonalities(personalities, for: baseURL)
    }

    static func removeAll(from baseURL: URL) throws {
        for url in avatarURLs(for: baseURL) {
            try PersistentFile.removeIfPresent(url)
        }
        try PersistentFile.removeIfPresent(personalityURL(for: baseURL))
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
        guard !personalities.isEmpty else {
            try PersistentFile.removeIfPresent(url)
            return
        }
        try PersistentFile.write(JSONEncoder().encode(personalities), to: url)
    }

    private static func personalityURL(for baseURL: URL) -> URL {
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        return baseURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-personalities.json")
    }
}

// Photo-less bots keep one preview image in settings, then get a stable Moods variant
// chosen from the session id wherever the active session shows the bot.
enum AgentAvatarArt {
    static let sessionArtworkCount = 64

    private static let personalityArtwork: [AgentPersonality: Int] = [
        .standard: 16,
        .sarcastic: 1,
        .cat: 7,
        .sextou: 13,
        .british: 5,
        .manager: 10,
        .frenchManager: 22,
    ]

    private static let sessionPictures: [Int: Data] = Dictionary(
        uniqueKeysWithValues: (1...sessionArtworkCount).compactMap { index in
            AppResources.bundle
                .url(forResource: String(format: "avatar-moods-%02d", index),
                     withExtension: "png")
                .flatMap { try? Data(contentsOf: $0) }
                .map { (index, $0) }
        })

    // Builds before Moods used these files as their photo-less bot artwork. They remain
    // bundled so those saved bots are still recognized as stock rather than user photos.
    static let legacyArtworkNames = [
        "default", "sarcastic", "cat", "sextou", "british", "manager"
    ]

    private static let legacyPictures: [Data] = legacyArtworkNames.compactMap {
        AppResources.bundle
            .url(forResource: "avatar-\($0)", withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }
    }

    private static let stockPictures = Set(sessionPictures.values).union(legacyPictures)

    static func pngData(for personality: AgentPersonality) throws -> Data {
        guard let index = personalityArtwork[personality],
              let data = sessionPictures[index] else {
            throw AgentAvatarError.missingArtwork
        }
        return data
    }

    static func isStock(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isStock(data: data)
    }

    static func isStock(data: Data) -> Bool {
        stockPictures.contains(data)
    }

    // Decoded once: settings and session rows ask for the same images on every redraw.
    @MainActor private static let personalityImages: [AgentPersonality: NSImage] =
        personalityArtwork.reduce(into: [:]) { images, entry in
            guard let data = sessionPictures[entry.value], let image = NSImage(data: data) else {
                return
            }
            images[entry.key] = image
        }

    @MainActor private static let sessionImages: [NSImage] = sessionPictures.keys.sorted()
        .compactMap { sessionPictures[$0].flatMap(NSImage.init(data:)) }

    @MainActor
    static func image(for personality: AgentPersonality) -> NSImage {
        personalityImages[personality] ?? NSImage(size: NSSize(width: 1, height: 1))
    }

    @MainActor
    static func sessionImage(for sessionID: UUID, avatarName: String) -> NSImage? {
        guard let index = sessionArtworkIndex(
            sessionID: sessionID,
            avatarName: avatarName,
            count: sessionImages.count) else { return nil }
        return sessionImages[index]
    }

    static func sessionArtworkIndex(sessionID: UUID, avatarName: String,
                                    count: Int = sessionArtworkCount) -> Int? {
        guard count > 0 else { return nil }
        // Derived from the id rather than stored, so a session record needs no extra field
        // to keep the same face.
        return Int(StableHash.fnv1a("\(sessionID.uuidString)|\(avatarName)") % UInt64(count))
    }
}

enum AgentAvatarError: LocalizedError {
    case couldNotReadImage
    case couldNotEncodeImage
    case missingArtwork
    case tooManyAvatars

    var errorDescription: String? {
        switch self {
        case .couldNotReadImage:
            "The selected file is not an image the app can read."
        case .couldNotEncodeImage:
            "The selected image could not be prepared for use."
        case .missingArtwork:
            "The picture for this personality is missing from the app."
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

struct SessionBotPicker: View {
    let avatars: [AgentAvatar]
    @Binding var selectedName: String
    let sessionID: UUID?
    let size: CGFloat

    init(avatars: [AgentAvatar], selectedName: Binding<String>,
         sessionID: UUID? = nil, size: CGFloat = 30) {
        self.avatars = avatars
        _selectedName = selectedName
        self.sessionID = sessionID
        self.size = size
    }

    private var selectedAvatar: AgentAvatar {
        AgentAvatarSelection.avatar(named: selectedName, from: avatars)
    }

    private var title: String {
        selectedAvatar.personality.title
    }

    var body: some View {
        selectedImage
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .background(Circle().fill(Theme.accentFill))
                    .overlay(Circle().stroke(Theme.card, lineWidth: size * 0.05))
            }
            .frame(width: max(size, 32), height: max(size, 32))
            .contentShape(Rectangle())
            .appMenu(edge: .top) { menu }
            .appTooltip("Choose bot: \(title)")
            .accessibilityLabel("Choose bot, \(title) selected")
    }

    private var selectedImage: some View {
        AgentAvatarView(image: selectedAvatar.displayImage(for: sessionID), size: size)
    }

    private var menu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(AgentPersonality.standard.title,
                  image: AgentAvatarSelection.avatar(named: nil, from: [])
                      .displayImage(for: sessionID),
                  checked: AgentAvatarSelection.resolvedName(
                    selectedName,
                    availableNames: avatars.map { $0.url.lastPathComponent })
                    == AgentAvatarSelection.defaultName,
                  subtitle: AgentPersonality.standard.detail) {
                selectedName = AgentAvatarSelection.defaultName
            }
        ]
        if !avatars.isEmpty {
            entries.append(.separator)
        }
        entries.append(contentsOf: avatars.map { avatar in
            .item(avatar.personality.title,
                  image: avatar.displayImage(for: sessionID),
                  checked: selectedName == avatar.url.lastPathComponent,
                  subtitle: avatar.personality.detail) {
                selectedName = avatar.url.lastPathComponent
            }
        })
        return entries
    }
}
