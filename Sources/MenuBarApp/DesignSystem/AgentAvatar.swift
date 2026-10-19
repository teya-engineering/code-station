import AppKit
import ImageIO
import SwiftUI
import CodeStationCore

struct AgentAvatar: Identifiable {
    let url: URL
    let image: NSImage
    let personality: AgentPersonality
    let picture: BotPicture

    var usesStockArtwork: Bool { picture == .automatic }

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
            picture: .automatic)
    }
}

enum AgentAvatarFile {
    static let maxPixelSize = 512
    static let maxCount = 5

    static func load(from url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func loadAll(from baseURL: URL) -> [AgentAvatar] {
        let records = (try? loadRecords(from: baseURL)) ?? [:]
        return avatarURLs(for: baseURL).compactMap { url in
            guard let image = load(from: url) else { return nil }
            let record = records[url.lastPathComponent]
            return AgentAvatar(url: url, image: image,
                               personality: record?.personality ?? .standard,
                               picture: record?.picture ?? legacyPicture(at: url))
        }
    }

    static func importImages(from sourceURLs: [URL],
                             to baseURL: URL,
                             personality: AgentPersonality = .standard) throws -> [AgentAvatar] {
        let prepared = try sourceURLs.map { try prepareImage(from: $0) }
        return try store(prepared, to: baseURL, personality: personality, picture: .photo)
    }

    private static func store(_ prepared: [(data: Data, image: NSImage)],
                              to baseURL: URL,
                              personality: AgentPersonality,
                              picture: BotPicture) throws -> [AgentAvatar] {
        guard !prepared.isEmpty else { return [] }
        let existing = avatarURLs(for: baseURL)
        guard existing.count + prepared.count <= maxCount else {
            throw AgentAvatarError.tooManyAvatars
        }
        var records = try loadRecords(from: baseURL)
        // Removed names stay reserved because saved sessions still refer to them.
        let reserved = records.keys.map { baseURL.deletingLastPathComponent().appendingPathComponent($0) }
        let nextIndex = ((existing + reserved).compactMap {
            avatarIndex(for: $0, baseURL: baseURL)
        }.max() ?? 0) + 1
        let destinations = prepared.indices.map { avatarURL(index: nextIndex + $0, baseURL: baseURL) }
        for destination in destinations {
            records[destination.lastPathComponent] = Record(personality: personality, picture: picture)
        }

        var written: [URL] = []
        do {
            for (item, destination) in zip(prepared, destinations) {
                try PersistentFile.write(item.data, to: destination)
                written.append(destination)
            }
            try saveRecords(records, for: baseURL)
        } catch {
            for url in written { try? PersistentFile.removeIfPresent(url) }
            throw error
        }
        return zip(destinations, prepared).map {
            AgentAvatar(url: $0.0, image: $0.1.image, personality: personality, picture: picture)
        }
    }

    static func addStockPicture(personality: AgentPersonality,
                                to baseURL: URL) throws -> [AgentAvatar] {
        [try save(personality: personality, picture: .automatic, photoData: nil, to: baseURL)]
    }

    static func save(personality: AgentPersonality, picture: BotPicture, photoData: Data?,
                     replacing avatar: AgentAvatar? = nil, to baseURL: URL) throws -> AgentAvatar {
        let data: Data
        switch picture {
        case .automatic: data = try AgentAvatarArt.pngData(for: personality)
        case .character(let index): data = try AgentAvatarArt.pngData(character: index)
        case .photo:
            guard let photoData else { throw AgentAvatarError.couldNotReadImage }
            data = photoData
        }
        guard let image = NSImage(data: data) else { throw AgentAvatarError.couldNotReadImage }
        guard let avatar else {
            return try store([(data, image)], to: baseURL,
                             personality: personality, picture: picture)[0]
        }
        guard avatarURLs(for: baseURL).contains(where: { $0.standardizedFileURL == avatar.url.standardizedFileURL }) else {
            throw AgentAvatarError.missingBot
        }
        var records = try loadRecords(from: baseURL)
        records[avatar.url.lastPathComponent] = Record(personality: personality, picture: picture)
        let original = try Data(contentsOf: avatar.url)
        try PersistentFile.write(data, to: avatar.url)
        do {
            try saveRecords(records, for: baseURL)
        } catch {
            try PersistentFile.write(original, to: avatar.url)
            throw error
        }
        return AgentAvatar(url: avatar.url, image: image, personality: personality, picture: picture)
    }

    static func setPersonality(_ personality: AgentPersonality,
                               for avatar: AgentAvatar,
                               baseURL: URL) throws -> AgentAvatar {
        try save(personality: personality, picture: avatar.picture,
                 photoData: avatar.picture == .photo ? Data(contentsOf: avatar.url) : nil,
                 replacing: avatar, to: baseURL)
    }

    static func remove(at url: URL, from baseURL: URL) throws {
        guard avatarURLs(for: baseURL).contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        var records = try loadRecords(from: baseURL)
        if records[url.lastPathComponent] == nil {
            records[url.lastPathComponent] = Record(personality: .standard, picture: legacyPicture(at: url))
        }
        try saveRecords(records, for: baseURL)
        try PersistentFile.removeIfPresent(url)
    }

    static func removeAll(from baseURL: URL) throws {
        for url in avatarURLs(for: baseURL) { try remove(at: url, from: baseURL) }
    }

    private static func legacyPicture(at url: URL) -> BotPicture {
        AgentAvatarArt.isStock(at: url) ? .automatic : .photo
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

    private struct Record: Codable {
        let personality: AgentPersonality
        let picture: BotPicture?

        init(personality: AgentPersonality, picture: BotPicture?) {
            self.personality = personality
            self.picture = picture
        }

        private enum CodingKeys: String, CodingKey { case personality, picture }

        init(from decoder: Decoder) throws {
            if let legacy = try? decoder.singleValueContainer().decode(String.self) {
                personality = AgentPersonality(rawValue: legacy) ?? .standard
                picture = nil
            } else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let name = try values.decode(String.self, forKey: .personality)
                personality = AgentPersonality(rawValue: name) ?? .standard
                picture = try values.decodeIfPresent(BotPicture.self, forKey: .picture)
            }
        }
    }

    private static func loadRecords(from baseURL: URL) throws -> [String: Record] {
        try PersistentFile.loadJSON([String: Record].self, from: personalityURL(for: baseURL)) ?? [:]
    }

    private static func saveRecords(_ records: [String: Record], for baseURL: URL) throws {
        try PersistentFile.saveJSON(records, to: personalityURL(for: baseURL))
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
    static let gallery = [16, 1, 7, 13, 5, 10, 22, 12, 44, 9, 18, 23]

    static func suggestedCharacter(for personality: AgentPersonality) -> Int {
        personalityArtwork[personality] ?? 16
    }

    static func pngData(character index: Int) throws -> Data {
        guard gallery.contains(index), let data = sessionPictures[index] else {
            throw AgentAvatarError.missingArtwork
        }
        return data
    }

    @MainActor
    static func image(character index: Int) -> NSImage {
        galleryImages[index] ?? image(for: .standard)
    }

    @MainActor private static let galleryImages: [Int: NSImage] = Dictionary(
        uniqueKeysWithValues: gallery.compactMap { index in
            sessionPictures[index].flatMap(NSImage.init(data:)).map { (index, $0) }
        })

    private static let personalityArtwork: [AgentPersonality: Int] = [
        .standard: 16,
        .sarcastic: 1,
        .cat: 7,
        .sextou: 13,
        .british: 5,
        .manager: 10,
        .frenchManager: 22,
        .navySeal: 12,
        .calceteiro: 44,
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
    case missingBot

    var errorDescription: String? {
        switch self {
        case .couldNotReadImage:
            "The selected file is not an image the app can read."
        case .couldNotEncodeImage:
            "The selected image could not be prepared for use."
        case .missingArtwork:
            "The picture for this personality is missing from the app."
        case .missingBot:
            "This bot is no longer available. Return to Your bots and add a new one."
        case .tooManyAvatars:
            "The app supports up to \(AgentAvatarFile.maxCount) custom bots. Remove one to add another."
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
    var showsName = false

    init(avatars: [AgentAvatar], selectedName: Binding<String>,
         sessionID: UUID? = nil, size: CGFloat = 30, showsName: Bool = false) {
        self.avatars = avatars
        _selectedName = selectedName
        self.sessionID = sessionID
        self.size = size
        self.showsName = showsName
    }

    private var selectedAvatar: AgentAvatar {
        AgentAvatarSelection.avatar(named: selectedName, from: avatars)
    }

    private var title: String {
        selectedAvatar.personality.title
    }

    var body: some View {
        label
            .contentShape(Rectangle())
            .appMenu(edge: .top) { menu }
            .appTooltip("Choose bot: \(title)")
            .accessibilityLabel("Choose bot, \(title) selected")
    }

    @ViewBuilder private var label: some View {
        if showsName {
            HStack(spacing: 8) {
                selectedImage
                Text(title).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        } else {
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
        }
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
