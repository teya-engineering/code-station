import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CodeStationCore
@testable import MenuBarApp

@MainActor
struct BotSettingsTests {
    private let scratch = ScratchDirectory(prefix: "bot-settings-tests")
    private var destination: URL { scratch.url.appendingPathComponent("agent-avatar.png") }

    @Test func automaticPictureFollowsPersonalityUntilACharacterIsChosen() throws {
        let draft = try BotDraft()
        #expect(!draft.isDirty)
        draft.personality = .cat
        #expect(draft.selectedCharacter == AgentAvatarArt.suggestedCharacter(for: .cat))
        draft.picture = .character(7)
        draft.personality = .manager
        #expect(draft.selectedCharacter == 7)
        #expect(draft.isDirty)
    }

    @Test func choosingTheSuggestedCharacterIsAnExplicitEdit() throws {
        let avatar = try AgentAvatarFile.save(personality: .cat, picture: .automatic, photoData: nil, to: destination)
        let draft = try BotDraft(avatar: avatar)
        draft.picture = .character(7)
        #expect(draft.isDirty)
        _ = try AgentAvatarFile.save(personality: draft.personality, picture: draft.picture,
                                     photoData: draft.photoData, replacing: avatar, to: destination)
        let restored = try #require(AgentAvatarFile.loadAll(from: destination).first)
        #expect(restored.picture == .character(7))
        #expect(!restored.usesStockArtwork)
        #expect(restored.displayImage(for: UUID()) === restored.image)
        _ = try AgentAvatarFile.setPersonality(.british, for: restored, baseURL: destination)
        #expect(try Data(contentsOf: destination) == AgentAvatarArt.pngData(character: 7))
        #expect(AgentAvatarFile.loadAll(from: destination).first?.picture == .character(7))
    }

    @Test func automaticArtworkStillVariesBySessionAfterSaving() throws {
        let draft = try BotDraft()
        draft.personality = .sextou
        let avatar = try AgentAvatarFile.save(personality: draft.personality, picture: draft.picture,
                                               photoData: nil, to: destination)
        #expect(avatar.usesStockArtwork)
        #expect(avatar.displayImage(for: UUID()) !== avatar.image)
        #expect(AgentAvatarFile.loadAll(from: destination).first?.picture == .automatic)
    }

    @Test func oldPersonalityRecordsKeepTheirArtworkBehaviorWhenMigrated() throws {
        try AgentAvatarArt.pngData(for: .cat).write(to: destination)
        let metadata = scratch.url.appendingPathComponent("agent-avatar-personalities.json")
        try Data(#"{"agent-avatar.png":"cat"}"#.utf8).write(to: metadata)
        let legacy = try #require(AgentAvatarFile.loadAll(from: destination).first)
        #expect(legacy.personality == .cat)
        #expect(legacy.picture == .automatic)
        _ = try AgentAvatarFile.setPersonality(.sextou, for: legacy, baseURL: destination)
        #expect(AgentAvatarFile.loadAll(from: destination).first?.personality == .sextou)
        #expect(try Data(contentsOf: destination) == AgentAvatarArt.pngData(for: .sextou))
    }

    @Test func photoAndDefaultAreSavedOnlyOnSave() throws {
        let suite = "bot-draft-default-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { removeScratchDefaults(suite) }
        let settings = AppSettings(agentAvatarURL: destination, preferences: preferences)
        let draft = try BotDraft()
        draft.personality = .sarcastic
        draft.picture = .photo
        draft.photoData = try pictureData()
        draft.isDefault = true
        #expect(settings.agentAvatars.isEmpty)
        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)
        try settings.saveBot(draft)
        let saved = try #require(settings.agentAvatars.first)
        #expect(settings.defaultAgentAvatarName == saved.url.lastPathComponent)
        let editing = try BotDraft(avatar: saved, defaultName: settings.defaultAgentAvatarName)
        #expect(!editing.isDirty)
        editing.personality = .cat
        editing.isDefault = false
        #expect(settings.agentAvatars.first?.personality == .sarcastic)
        try settings.saveBot(editing)
        #expect(settings.agentAvatars.count == 1)
        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)
        #expect(try Data(contentsOf: destination) == draft.photoData)
        let restored = try #require(AppSettings(agentAvatarURL: destination, preferences: preferences).agentAvatars.first)
        #expect(restored.personality == .cat)
        #expect(restored.picture == .photo)
        #expect(restored.displayImage(for: UUID()) === restored.image)
    }

    @Test func revertingAnEditMakesTheDraftClean() throws {
        let draft = try BotDraft()
        draft.personality = .cat
        draft.isDefault = true
        #expect(draft.isDirty)
        draft.personality = .standard
        draft.isDefault = false
        #expect(!draft.isDirty)
    }

    @Test func abandonedPhotoDoesNotDirtyAnUnchangedCharacter() throws {
        let avatar = try AgentAvatarFile.save(personality: .cat, picture: .character(7), photoData: nil, to: destination)
        let draft = try BotDraft(avatar: avatar)
        draft.photoData = try pictureData()
        draft.picture = .photo
        #expect(draft.isDirty)
        draft.picture = .character(7)
        #expect(!draft.isDirty)
    }

    @Test func dirtyDraftProtectsNavigationUntilDiscarded() throws {
        let flow = BotSettingsFlow()
        let dialogs = DialogPresenter()
        let draft = try BotDraft()
        draft.personality = .cat
        flow.draft = draft
        var navigations = 0
        flow.leave(using: dialogs) { navigations += 1 }
        #expect(navigations == 0)
        #expect(flow.draft === draft)
        #expect(dialogs.current?.isModal == true)
        dialogs.dismiss()
        #expect(flow.draft === draft)
        #expect(navigations == 0)
        flow.leave(using: dialogs) { navigations += 1 }
        let discard = try #require(dialogs.current?.actions.first { $0.kind == .primary })
        dialogs.run(discard)
        #expect(navigations == 1)
        #expect(flow.draft == nil)
    }

    @Test func cleanDraftCanLeaveWithoutAQuestion() throws {
        let flow = BotSettingsFlow()
        let dialogs = DialogPresenter()
        flow.draft = try BotDraft()
        var navigated = false
        flow.leave(using: dialogs) { navigated = true }
        #expect(navigated)
        #expect(flow.draft == nil)
        #expect(dialogs.current == nil)
    }

    @Test func savingAtCapacityFailsWithoutChangingDefaultOrDiscardingDraft() throws {
        let suite = "bot-capacity-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { removeScratchDefaults(suite) }
        let settings = AppSettings(agentAvatarURL: destination, preferences: preferences)
        for _ in 0..<AgentAvatarFile.maxCount { try settings.addStockAgentAvatar(personality: .cat) }
        let draft = try BotDraft()
        draft.personality = .manager
        draft.isDefault = true
        #expect(throws: AgentAvatarError.self) { try settings.saveBot(draft) }
        #expect(settings.agentAvatars.count == AgentAvatarFile.maxCount)
        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)
        #expect(draft.personality == .manager)
        let existing = try BotDraft(avatar: settings.agentAvatars[0])
        existing.personality = .british
        try settings.saveBot(existing)
        #expect(settings.agentAvatars.count == AgentAvatarFile.maxCount)
        #expect(settings.agentAvatars[0].personality == .british)
    }

    @Test func removedNamesAreNeverReusedByNewBots() throws {
        let first = try AgentAvatarFile.save(personality: .cat, picture: .automatic, photoData: nil, to: destination)
        try AgentAvatarFile.remove(at: first.url, from: destination)
        let second = try AgentAvatarFile.save(personality: .british, picture: .automatic, photoData: nil, to: destination)
        #expect(second.url != first.url)
        #expect(AgentAvatarSelection.avatar(named: first.url.lastPathComponent, from: [second])
            .url.lastPathComponent == AgentAvatarSelection.defaultName)
        try AgentAvatarFile.removeAll(from: destination)
        let third = try AgentAvatarFile.save(personality: .cat, picture: .automatic, photoData: nil, to: destination)
        #expect(third.url != first.url && third.url != second.url)
    }

    @Test func unreadableMetadataDoesNotOverwriteTheSavedPicture() throws {
        let avatar = try AgentAvatarFile.save(personality: .cat, picture: .automatic, photoData: nil, to: destination)
        let before = try Data(contentsOf: destination)
        try Data("invalid json".utf8).write(to: scratch.url.appendingPathComponent("agent-avatar-personalities.json"))
        #expect(throws: (any Error).self) {
            try AgentAvatarFile.save(personality: .manager, picture: .character(10), photoData: nil,
                                      replacing: avatar, to: destination)
        }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test func searchFindsTheCollectionForBotEditingAndPictures() {
        for query in ["bot", "edit bot", "picture", "default bot"] {
            #expect(SettingsSearchIndex.results(for: query).contains { $0.target == .appearanceDefaultBot })
        }
    }

    @Test func cropStaysWithinTheImageAtEveryEdgeAndZoom() {
        for size in [CGSize(width: 800, height: 400), CGSize(width: 400, height: 800)] {
            for zoom in [1.0, 1.5, 2.5] {
                for across in [-1.0, 0, 1] {
                    for down in [-1.0, 0, 1] {
                        let rect = BotPhotoCrop.sourceRect(size: size, zoom: zoom, across: across, down: down)
                        #expect(CGRect(origin: .zero, size: size).contains(rect))
                        #expect(rect.width == rect.height)
                        let expectedSide = min(size.width, size.height) / CGFloat(zoom)
                        #expect(abs(rect.width - expectedSide) < 0.001)
                    }
                }
            }
        }
    }

    @Test func cropExportsASquare512PixelPNG() throws {
        let source = scratch.url.appendingPathComponent("photo.png")
        try pictureData().write(to: source)
        let crop = BotPhotoCrop(image: try BotPhoto.read(from: source))
        crop.zoom = 1.7
        crop.across = -0.7
        let output = try crop.pngData()
        let decoder = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        #expect(result.width == 512)
        #expect(result.height == 512)
        #expect(CGImageSourceGetType(decoder) as String? == UTType.png.identifier)
    }

    @Test func photoImportValidatesSizeContentsAndFormat() throws {
        let source = scratch.url.appendingPathComponent("photo.png")
        try Data(repeating: 0, count: BotPhoto.maxBytes + 1).write(to: source)
        #expect(throws: BotPhoto.ImportError.tooLarge) { try BotPhoto.read(from: source) }
        try Data("not a picture".utf8).write(to: source)
        #expect(throws: BotPhoto.ImportError.unreadable) { try BotPhoto.read(from: source) }
        let bitmap = try #require(NSBitmapImageRep(data: pictureData()))
        let gif = try #require(bitmap.representation(using: .gif, properties: [:]))
        try gif.write(to: source)
        #expect(throws: BotPhoto.ImportError.unsupported) { try BotPhoto.read(from: source) }
        for type in [NSBitmapImageRep.FileType.png, .jpeg] {
            try #require(bitmap.representation(using: type, properties: [:])).write(to: source)
            let image = try BotPhoto.read(from: source)
            #expect(image.width > 0 && image.height > 0)
        }
    }

    @Test func imageOrientationIsAppliedBeforeCropping() throws {
        let source = scratch.url.appendingPathComponent("portrait.jpg")
        let bitmap = try #require(NSBitmapImageRep(data: pictureData()))
        let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(bitmap.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        let image = try BotPhoto.read(from: source)
        #expect(image.height > image.width)
    }

    @Test func cropPositionSelectsThePartShownInThePreview() throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
                                             bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 400, y: 0, width: 400, height: 400))
        let crop = BotPhotoCrop(image: try #require(context.makeImage()))
        for across in [-1.0, 1] {
            crop.across = across
            let bitmap = try #require(NSBitmapImageRep(data: crop.pngData()))
            let color = try #require(bitmap.colorAt(x: 256, y: 256)?.usingColorSpace(.deviceRGB))
            #expect(across == 1 ? color.redComponent > 0.95 : color.blueComponent > 0.95)
        }
    }

    private func pictureData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
                                             bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]))
    }
}
