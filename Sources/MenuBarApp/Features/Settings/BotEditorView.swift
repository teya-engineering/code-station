import SwiftUI
import UniformTypeIdentifiers

struct BotEditorView: View {
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var draft: BotDraft
    let portraits: Namespace.ID
    let cancel: () -> Void
    @State private var tab = Tab.personality
    @State private var imageError: String?
    @State private var dragging = false
    @State private var availableWidth: CGFloat = 722
    @FocusState private var focusedTab: Tab?
    @FocusState private var focusedPersonality: AgentPersonality?
    @FocusState private var focusedCharacter: Int?

    private enum Tab: String, CaseIterable { case personality = "Personality", picture = "Picture" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Button(action: cancel) {
                Label("Your bots", systemImage: "arrow.left")
                    .font(Typography.detail).foregroundStyle(Theme.accent)
                    .padding(.vertical, Space.xxs).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(draft.isNew ? "Make a new friend" : "Edit \(draft.personality.title)").font(.logo(25))
                Text(draft.isNew ? "Give your next session a little character." : "Fine-tune the face and personality you work with.")
                    .font(Typography.body).foregroundStyle(.secondary)
            }
            if availableWidth >= 650 {
                HStack(alignment: .top, spacing: Space.xxl) {
                    choices.frame(maxWidth: .infinity)
                    preview.frame(width: 232)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    choices
                    preview
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.sm) {
                ForEach(Tab.allCases, id: \.self) { choice in
                    ChoicePill(title: choice.rawValue, selected: tab == choice) { tab = choice }
                        .frame(maxWidth: .infinity)
                        .focused($focusedTab, equals: choice)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(focusedTab == choice ? Theme.accent : .clear, lineWidth: 2))
                        .accessibilityLabel("\(choice.rawValue) tab")
                        .accessibilityValue(tab == choice ? "Selected" : "Not selected")
                }
            }
            .padding(Space.xs).surface(Theme.field, cornerRadius: Radius.card)
            .onMoveCommand { direction in
                guard direction == .left || direction == .right else { return }
                tab = tab == .personality ? .picture : .personality
                focusedTab = tab
            }
            if tab == .personality {
                personalities.transition(.fadeIn)
            } else {
                pictures.transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: tab)
    }

    private var personalities: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("What's their personality?").font(Typography.body.weight(.semibold))
                Text("A different voice for the little moments between prompts.")
                    .font(Typography.detail).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.md)], spacing: Space.md) {
                ForEach(AgentPersonality.allCases, id: \.self) { personality in
                    personalityChoice(personality)
                }
            }
            .onMoveCommand { direction in
                let choices = AgentPersonality.allCases
                let index = choices.firstIndex(of: focusedPersonality ?? draft.personality) ?? 0
                let next = choices[(index + step(direction) + choices.count) % choices.count]
                draft.personality = next
                focusedPersonality = next
            }
            Label("Personality changes working messages. Your agent's capabilities and instructions stay the same.", systemImage: "info.circle")
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personality choices")
    }

    private func personalityChoice(_ personality: AgentPersonality) -> some View {
        let selected = draft.personality == personality
        return Button { draft.personality = personality } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    BotPortrait(image: AgentAvatarArt.image(for: personality), size: 30)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
                Text(personality.title).font(Typography.label)
                Text(personality.detail).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .surface(selected ? Theme.botSelection : Theme.card, cornerRadius: Radius.floating,
                     border: selected ? Theme.accent.opacity(0.65) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
        }
        .buttonStyle(.plain)
        .focused($focusedPersonality, equals: personality)
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
            .stroke(focusedPersonality == personality ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityLabel("\(personality.title). \(personality.detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .hoverLift()
    }

    private var pictures: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("A face to put to the personality").font(Typography.body.weight(.semibold))
                Text("Choose a character, or make it personal with a photo.")
                    .font(Typography.detail).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Space.md)], spacing: Space.md) {
                ForEach(Array(AgentAvatarArt.gallery.enumerated()), id: \.element) { position, index in
                    characterChoice(index, position: position)
                }
            }
            .onMoveCommand { direction in
                let choices = AgentAvatarArt.gallery
                let index = choices.firstIndex(of: focusedCharacter ?? draft.selectedCharacter ?? choices[0]) ?? 0
                let next = choices[(index + step(direction) + choices.count) % choices.count]
                draft.picture = .character(next)
                focusedCharacter = next
            }
            Button(action: choosePhoto) {
                HStack(spacing: Space.lg) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(draft.picture == .photo ? "Replace your photo" : "Upload a photo")
                            .font(Typography.label)
                        Text("Drop a picture here or choose a file")
                            .font(Typography.caption).foregroundStyle(.secondary)
                        Text("JPG, PNG, WebP · Up to 10 MB")
                            .font(Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .background(dragging ? Theme.botSelection : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
                .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                    .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5])))
                .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
                .motion(Motion.hover, value: dragging)
            }
            .buttonStyle(.plain)
            .hoverLift()
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                importPhoto(url)
                return true
            } isTargeted: { dragging = $0 }
            if let imageError {
                Text(imageError).font(Typography.detail).foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.fadeIn)
            }
            HStack {
                Text("Your picture stays on this Mac.").font(Typography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if draft.picture == .photo {
                    InlineLink(title: "Adjust crop") {
                        if let source = draft.cropSource ?? draft.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            crop(source)
                        }
                    }
                }
            }
        }
        .motion(Motion.reveal, value: imageError)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture choices")
    }

    private func characterChoice(_ index: Int, position: Int) -> some View {
        let selected = draft.selectedCharacter == index
        return Button {
            draft.picture = .character(index)
            imageError = nil
        } label: {
            BotPortrait(image: AgentAvatarArt.image(character: index), size: 52)
                .padding(Space.xs)
                .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                    .stroke(selected || focusedCharacter == index ? Theme.accent : .clear, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            .background(Circle().fill(Theme.card)).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
        }
        .buttonStyle(.plain)
        .focused($focusedCharacter, equals: index)
        .accessibilityLabel(index == AgentAvatarArt.suggestedCharacter(for: draft.personality)
                            ? "Character \(position + 1), suggested for \(draft.personality.title)" : "Character \(position + 1)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .hoverLift()
    }

    private var preview: some View {
        VStack(spacing: Space.lg) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    BotPortraitStage(image: draft.image, size: 110, portraits: portraits,
                                     portraitID: draft.avatar?.id.absoluteString ?? "new-bot")
                        .id(previewIdentity)
                        // The stage holds only drawn shapes and a picture, so it can settle
                        // from a slight scale without upsetting AppKit layout.
                        .transition(reduceMotion ? .opacity.animation(Motion.reveal)
                                                 : .opacity.combined(with: .scale(scale: 0.94)))
                    Text("Live preview").font(Font.system(size: Typography.Size.micro, weight: .medium))
                        .foregroundStyle(Theme.onFill).padding(Space.lg)
                }
                .frame(height: 186)
                .motion(Motion.reveal, value: previewIdentity)
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text(draft.personality.title).font(.logo(16))
                    Text("While your bot is working").font(Typography.caption).foregroundStyle(.secondary)
                    BotWorkingLine(personality: draft.personality)
                    Divider().overlay(Theme.border)
                    HStack {
                        Text("In your sidebar")
                        Spacer()
                        Text("Actual size")
                    }
                    .font(Typography.caption).foregroundStyle(.secondary)
                    HStack(spacing: Space.md) {
                        AgentAvatarView(image: draft.image, size: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Polish the settings screen").font(Typography.caption.weight(.medium))
                            Text(draft.personality.title).font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.md).surface(Theme.field, cornerRadius: Radius.control)
                    HStack(spacing: Space.lg) {
                        ForEach([40.0, 28, 18], id: \.self) { size in
                            AgentAvatarView(image: draft.image, size: size)
                                .accessibilityLabel("Avatar at \(Int(size)) points")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(Space.xl)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
            .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
            SettingsToggleRow("Default for new sessions", detail: "Start your next session with this bot.", isOn: $draft.isDefault)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bot preview")
    }

    private var previewIdentity: String {
        draft.selectedCharacter.map { "character-\($0)" } ?? "photo-\(draft.photoData?.hashValue ?? 0)"
    }

    private func step(_ direction: MoveCommandDirection) -> Int {
        switch direction {
        case .left, .up: -1
        case .right, .down: 1
        @unknown default: 0
        }
    }

    private func choosePhoto() {
        guard let url = FilePicker.chooseFile(prompt: "Choose picture", message: "Pick a photo for this bot.",
                                              types: [.png, .jpeg, .webP]) else { return }
        importPhoto(url)
    }

    private func importPhoto(_ url: URL) {
        do {
            let image = try BotPhoto.read(from: url)
            imageError = nil
            crop(image)
        } catch {
            imageError = error.localizedDescription
            if let window = NSApp?.keyWindow {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: error.localizedDescription,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }

    private func crop(_ image: CGImage) {
        let crop = BotPhotoCrop(image: image)
        dialogs.show(Dialog(title: "Make it a good fit", message: "Keep the best part in the frame.",
                            content: AnyView(BotPhotoCropView(crop: crop) { data in
                                draft.photoData = data
                                draft.cropSource = image
                                draft.picture = .photo
                                imageError = nil
                            }), actions: [], width: 390, isModal: true))
    }
}
