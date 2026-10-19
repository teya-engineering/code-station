import SwiftUI
import UniformTypeIdentifiers
import CodeStationCore

struct BotEditorView: View {
    @Environment(DialogPresenter.self) private var dialogs
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
        VStack(alignment: .leading, spacing: 18) {
            Button(action: cancel) {
                Label("Your bots", systemImage: "arrow.left")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                    .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.isNew ? "Make a new friend" : "Edit \(draft.personality.title)").font(.logo(25))
                Text(draft.isNew ? "Give your next session a little character." : "Fine-tune the face and personality you work with.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if availableWidth >= 650 {
                HStack(alignment: .top, spacing: 20) {
                    choices.frame(maxWidth: .infinity)
                    preview.frame(width: 232)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    choices
                    preview
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { choice in
                    ChoicePill(title: choice.rawValue, selected: tab == choice) { tab = choice }
                        .frame(maxWidth: .infinity)
                        .focused($focusedTab, equals: choice)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(focusedTab == choice ? Theme.accent : .clear, lineWidth: 2))
                        .accessibilityLabel("\(choice.rawValue) tab")
                        .accessibilityValue(tab == choice ? "Selected" : "Not selected")
                }
            }
            .padding(4).surface(Theme.field, cornerRadius: 10)
            .onMoveCommand { direction in
                guard direction == .left || direction == .right else { return }
                tab = tab == .personality ? .picture : .personality
                focusedTab = tab
            }
            if tab == .personality { personalities } else { pictures }
        }
    }

    private var personalities: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What's their personality?").font(.system(size: 14, weight: .semibold))
                Text("A different voice for the little moments between prompts.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
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
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personality choices")
    }

    private func personalityChoice(_ personality: AgentPersonality) -> some View {
        let selected = draft.personality == personality
        return Button { draft.personality = personality } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    BotPortrait(image: AgentAvatarArt.image(for: personality), size: 30)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
                Text(personality.title).font(.system(size: 11.5, weight: .semibold))
                Text(personality.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .surface(selected ? Theme.botSelection : Theme.card, cornerRadius: 11,
                     border: selected ? Theme.accent.opacity(0.65) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .focused($focusedPersonality, equals: personality)
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(focusedPersonality == personality ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityLabel("\(personality.title). \(personality.detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .hoverLift()
    }

    private var pictures: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("A face to put to the personality").font(.system(size: 14, weight: .semibold))
                Text("Choose a character, or make it personal with a photo.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 10) {
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
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.picture == .photo ? "Replace your photo" : "Upload a photo")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Drop a picture here or choose a file")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("JPG, PNG, WebP · Up to 10 MB")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .background(dragging ? Theme.botSelection : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5])))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                importPhoto(url)
                return true
            } isTargeted: { dragging = $0 }
            if let imageError {
                Text(imageError).font(.system(size: 12)).foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Your picture stays on this Mac.").font(.system(size: 10.5)).foregroundStyle(.secondary)
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
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 15)
                    .stroke(selected || focusedCharacter == index ? Theme.accent : .clear, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            .background(Circle().fill(Theme.card)).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 15))
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
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    BotPortraitStage(image: draft.image, size: 110, portraits: portraits,
                                     portraitID: draft.avatar?.id.absoluteString ?? "new-bot")
                        .id(previewIdentity)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    Text("Live preview").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white).padding(12)
                }
                .frame(height: 186)
                .motion(.easeOut(duration: 0.28), value: previewIdentity)
                VStack(alignment: .leading, spacing: 14) {
                    Text(draft.personality.title).font(.logo(16))
                    Text("While your bot is working").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    BotWorkingLine(personality: draft.personality)
                    Divider().overlay(Theme.border)
                    HStack {
                        Text("In your sidebar")
                        Spacer()
                        Text("Actual size")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        AgentAvatarView(image: draft.image, size: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Polish the settings screen").font(.system(size: 10.5, weight: .medium))
                            Text(draft.personality.title).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8).surface(Theme.field, cornerRadius: 8)
                    HStack(spacing: 12) {
                        ForEach([40.0, 28, 18], id: \.self) { size in
                            AgentAvatarView(image: draft.image, size: size)
                                .accessibilityLabel("Avatar at \(Int(size)) points")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(15)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
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
