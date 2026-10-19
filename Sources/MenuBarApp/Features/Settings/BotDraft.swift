import AppKit
import Observation
import CodeStationCore

enum BotPicture: Codable, Equatable {
    case automatic
    case character(Int)
    case photo
}

@MainActor
@Observable
final class BotDraft {
    let avatar: AgentAvatar?
    var personality: AgentPersonality
    var picture: BotPicture
    var photoData: Data?
    var isDefault: Bool
    var cropSource: CGImage?

    private let originalPersonality: AgentPersonality
    private let originalPicture: BotPicture
    private let originalPhotoData: Data?
    private let originalDefault: Bool

    init(avatar: AgentAvatar? = nil, defaultName: String = AgentAvatarSelection.defaultName) throws {
        self.avatar = avatar
        let personality = avatar?.personality ?? .standard
        let picture = avatar?.picture ?? .automatic
        let photoData = try avatar.flatMap { $0.picture == .photo ? try Data(contentsOf: $0.url) : nil }
        let isDefault = avatar.map { $0.url.lastPathComponent == defaultName } ?? false
        self.personality = personality
        self.picture = picture
        self.photoData = photoData
        self.isDefault = isDefault
        originalPersonality = personality
        originalPicture = picture
        originalPhotoData = photoData
        originalDefault = isDefault
    }

    var isNew: Bool { avatar == nil }

    var isDirty: Bool {
        personality != originalPersonality || picture != originalPicture
            || (picture == .photo && photoData != originalPhotoData) || isDefault != originalDefault
    }

    var image: NSImage {
        switch picture {
        case .automatic: AgentAvatarArt.image(for: personality)
        case .character(let index): AgentAvatarArt.image(character: index)
        case .photo: photoData.flatMap(NSImage.init(data:)) ?? AgentAvatarArt.image(for: personality)
        }
    }

    var selectedCharacter: Int? {
        switch picture {
        case .automatic: AgentAvatarArt.suggestedCharacter(for: personality)
        case .character(let index): index
        case .photo: nil
        }
    }
}

@MainActor
@Observable
final class BotSettingsFlow {
    var isPresented = false
    var draft: BotDraft?
    var notice: String?
    var undoDefaultName: String?

    func leave(using dialogs: DialogPresenter, then action: @escaping () -> Void) {
        guard draft?.isDirty == true else {
            draft = nil
            action()
            return
        }
        var dialog = Dialog.confirm(
            "Leave without saving?",
            message: "Your picture and personality changes haven't been saved.",
            action: "Discard changes", kind: .primary, cancel: "Keep editing") {
                self.draft = nil
                action()
            }
        dialog.isModal = true
        dialogs.show(dialog)
    }

    func announce(_ message: String, undoDefaultName: String? = nil) {
        notice = message
        self.undoDefaultName = undoDefaultName
        if let window = NSApp?.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}
