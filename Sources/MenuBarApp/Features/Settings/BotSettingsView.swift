import SwiftUI
import CodeStationCore

struct BotSettingsEntry: View {
    @Environment(AppSettings.self) private var settings
    let open: () -> Void
    @FocusState private var focused: Bool

    private var current: AgentAvatar {
        AgentAvatarSelection.avatar(named: settings.defaultAgentAvatarName, from: settings.agentAvatars)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your bots").font(.logo(17))
                    Text("A little character for every session.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text("\(settings.agentAvatars.count + 1) \(settings.agentAvatars.isEmpty ? "bot" : "bots") in your collection")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                BotPortrait(image: current.displayImage(for: nil), size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(current.personality.title) is your default")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(current.personality.sampleLine)
                        .font(.serif(16, .regular).italic())
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Label("Manage bots", systemImage: "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accentFill))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.botSelection, cornerRadius: 14, border: Theme.accent.opacity(0.3))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .hoverLift()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Manage bots. Your current default is \(current.personality.title). \(settings.agentAvatars.count + 1) bots in your collection.")
    }
}

struct BotSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var flow: BotSettingsFlow
    let appearance: () -> Void
    @Namespace private var portraits
    @State private var returnBot: URL?
    @FocusState private var focusedBot: URL?

    private var current: AgentAvatar {
        AgentAvatarSelection.avatar(named: settings.defaultAgentAvatarName, from: settings.agentAvatars)
    }
    private var roster: [AgentAvatar] {
        [AgentAvatarSelection.avatar(named: nil, from: [])] + settings.agentAvatars
    }
    private var full: Bool { settings.agentAvatars.count >= AgentAvatarFile.maxCount }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let draft = flow.draft {
                        BotEditorView(draft: draft, portraits: portraits, cancel: back)
                    } else {
                        collection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .id(flow.draft == nil)
            if flow.notice != nil { notice }
            if let draft = flow.draft {
                SheetFooter(
                    title: draft.isNew ? "Ready when you are" : draft.isDirty ? "Unsaved changes" : "No changes yet",
                    primary: SheetAction(title: draft.isNew ? "Add bot" : "Save changes",
                                         enabled: draft.isNew || draft.isDirty,
                                         shortcut: KeyboardShortcut(.return, modifiers: .command), action: save),
                    dismissTitle: "Cancel", dismissTone: .outlined, primaryLast: true, dismiss: back) {
                        EmptyView()
                    }
            }
        }
        .background(Theme.background)
        .onChange(of: flow.draft == nil) { _, showingCollection in
            if showingCollection {
                Task { @MainActor in
                    await Task.yield()
                    focusedBot = returnBot
                }
            }
        }
    }

    private var notice: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
            Text(flow.notice ?? "").font(.system(size: 12))
            Spacer(minLength: 0)
            if let previous = flow.undoDefaultName {
                InlineLink(title: "Undo") {
                    settings.setDefaultAgentAvatarName(AgentAvatarSelection.resolvedName(
                        previous, availableNames: settings.agentAvatars.map { $0.url.lastPathComponent }))
                    flow.announce("Default bot restored.")
                }
            }
            Button { flow.notice = nil; flow.undoDefaultName = nil } label: {
                Image(systemName: "xmark").padding(6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }
        .padding(12)
        .background(Theme.botSelection)
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 7) {
                InlineLink(title: "Appearance", action: appearance)
                Image(systemName: "chevron.right").font(.system(size: 9))
                Text("Your bots").font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your bots").font(.logo(27))
                    Text("A familiar face. A little personality.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                ActionButton(title: "Add bot", tone: .green, height: 36, icon: "plus") { edit(nil) }
                    .disabled(full)
                    .appTooltip(full ? "Remove a custom bot to add another" : "Add a bot")
            }
            hero
            HStack(alignment: .lastTextBaseline) {
                Text("The whole crew").font(.logo(16))
                Spacer()
                Text("\(settings.agentAvatars.count) of \(AgentAvatarFile.maxCount) custom bots")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(roster) { avatar in card(avatar) }
                if !full {
                    Button { edit(nil) } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 23, weight: .light))
                                .frame(width: 44, height: 44).background(Circle().fill(Theme.card))
                            Text("Someone new?").font(.system(size: 13, weight: .semibold))
                            Text("Add a bot to your crew").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 188)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5])))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain).hoverLift()
                    .accessibilityLabel("Add bot")
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                Text(full ? "Your crew is full. Remove a custom bot to add another." : "Your default starts every new session. You can choose a different bot in any session.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                InlineLink(title: "How bots work") {
                    var dialog = Dialog.notice("A little company, your way.", message: "Bots give your sessions a familiar face and their own working messages. They work with whichever agent you choose.\n\nChoose from nine personalities and twelve characters, or use your own picture. Keep up to five custom bots, plus the original. Your default starts new sessions; existing sessions keep their bot.\n\nPersonality changes working messages. Your agent's capabilities and instructions stay the same.")
                    dialog.width = 450
                    dialog.isModal = true
                    dialogs.show(dialog)
                }
            }
            .padding(14).surface(Theme.sidebar, cornerRadius: 10)
            Label("Saved on this Mac", systemImage: "lock")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private var hero: some View {
        HStack(spacing: 0) {
            BotPortraitStage(image: current.displayImage(for: nil), size: 126,
                             portraits: portraits, portraitID: current.id.absoluteString)
                .frame(width: 196, height: 228)
            VStack(alignment: .leading, spacing: 9) {
                Label("Default for new sessions", systemImage: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.botSelection))
                Text(current.personality.title).font(.logo(23))
                Text(current.personality.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                BotWorkingLine(personality: current.personality, size: 20)
                ActionButton(title: current.url.lastPathComponent == AgentAvatarSelection.defaultName ? "Make it your own" : "Edit bot",
                             tone: .outlined, height: 32, icon: "pencil") { edit(current) }
                    .disabled(full && current.url.lastPathComponent == AgentAvatarSelection.defaultName)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
    }

    private func card(_ avatar: AgentAvatar) -> some View {
        let selected = current.id == avatar.id
        let builtIn = avatar.url.lastPathComponent == AgentAvatarSelection.defaultName
        return VStack(spacing: 0) {
            Button { edit(avatar) } label: {
                VStack(spacing: 8) {
                    BotPortrait(image: avatar.displayImage(for: nil), size: 60)
                        .matchedGeometryEffect(id: selected ? "card-\(avatar.id)" : avatar.id.absoluteString,
                                               in: portraits)
                    Text(avatar.personality.title).font(.system(size: 13, weight: .semibold))
                    Text(builtIn ? "The original" : "Edit picture and personality")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedBot, equals: avatar.id)
            .disabled(builtIn && full)
            .accessibilityLabel("\(builtIn ? "Customize" : "Edit") \(avatar.personality.title)")
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 12)
            Button { makeDefault(avatar) } label: {
                Label(selected ? "Default bot" : "Make default", systemImage: selected ? "checkmark" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 37)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(avatar.personality.title): \(selected ? "Default bot" : "Make default")")
            .accessibilityValue(selected ? "Selected" : "Not selected")
        }
        .background(selected ? Theme.botSelection : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(selected || focusedBot == avatar.id ? Theme.accent.opacity(0.7) : Theme.border,
                    lineWidth: focusedBot == avatar.id ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if !builtIn {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 28).contentShape(Rectangle())
                    .appMenu {
                        [.item("Edit bot", icon: "pencil") { edit(avatar) },
                         .item("Make default", icon: "star") { makeDefault(avatar) },
                         .separator,
                         .item("Remove bot", kind: .destructive, icon: "trash") { remove(avatar) }]
                    }
                    .accessibilityLabel("More options for \(avatar.personality.title)")
            }
        }
        .hoverLift()
    }

    private func edit(_ avatar: AgentAvatar?) {
        let custom = avatar?.url.lastPathComponent == AgentAvatarSelection.defaultName ? nil : avatar
        guard custom != nil || !full else { return }
        do {
            let draft = try BotDraft(avatar: custom, defaultName: settings.defaultAgentAvatarName)
            returnBot = avatar?.id
            flow.notice = nil
            flow.undoDefaultName = nil
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.36)) { flow.draft = draft }
        } catch {
            dialogs.show(.notice("Could not open this bot", message: error.localizedDescription))
        }
    }

    private func back() {
        flow.leave(using: dialogs) { }
    }

    private func save() {
        guard let draft = flow.draft, draft.isNew || draft.isDirty else { return }
        do {
            try settings.saveBot(draft)
            flow.draft = nil
            flow.announce(draft.isNew ? "\(draft.personality.title) joined your crew." : "\(draft.personality.title) is ready. Changes saved.")
        } catch {
            var dialog = Dialog.notice("Could not save this bot", message: "\(error.localizedDescription) Your draft is still here. Try saving again.")
            dialog.isModal = true
            dialogs.show(dialog)
        }
    }

    private func makeDefault(_ avatar: AgentAvatar) {
        let previous = settings.defaultAgentAvatarName
        guard previous != avatar.url.lastPathComponent else { return }
        settings.setDefaultAgentAvatarName(avatar.url.lastPathComponent)
        flow.announce("\(avatar.personality.title) will start new sessions.", undoDefaultName: previous)
    }

    private func remove(_ avatar: AgentAvatar) {
        dialogs.show(.impact("Remove \(avatar.personality.title)?",
                             message: "This makes room for someone new.", rows: [
                                .init(title: "Bot and saved picture", detail: "\(avatar.personality.title) is removed from your collection."),
                                .init(title: "Sessions and messages", detail: "All your work stays.", kept: true),
                                .init(title: "Bot selection", detail: "Sessions using this bot fall back to the built-in bot. If it is your default, new sessions use the built-in bot too.", kept: true),
                             ], warning: "This bot's picture and settings can't be restored.", action: "Remove bot") {
            do {
                try settings.removeAgentAvatar(avatar)
                flow.announce("\(avatar.personality.title) was removed.")
            } catch {
                dialogs.show(.notice("Could not remove this bot", message: error.localizedDescription))
            }
        })
    }
}

struct BotPortrait: View {
    let image: NSImage
    let size: CGFloat
    var body: some View {
        Image(nsImage: image).resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct BotPortraitStage: View {
    let image: NSImage
    let size: CGFloat
    var portraits: Namespace.ID? = nil
    var portraitID: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Theme.botStage.overlay {
            ZStack {
                Circle().stroke(.white.opacity(0.1)).frame(width: size * 1.35, height: size * 1.35)
                Circle().stroke(.white.opacity(0.08)).frame(width: size * 1.95, height: size * 1.95)
                portrait
                    .rotationEffect(.degrees(reduceMotion ? 0 : hovering ? 2 : -5))
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 7)
                    .offset(y: hovering && !reduceMotion ? -3 : 0)
            }
        }
        .clipped()
        .onHover { hovering = $0 }
        .motion(Motion.arrive, value: hovering)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var portrait: some View {
        if let portraits, let portraitID {
            BotPortrait(image: image, size: size)
                .matchedGeometryEffect(id: portraitID, in: portraits)
        } else {
            BotPortrait(image: image, size: size)
        }
    }
}

struct BotWorkingLine: View {
    let personality: AgentPersonality
    var size: CGFloat = 18
    @State private var line = 0
    @State private var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        Capsule().fill(Theme.accent)
                            .frame(width: 3, height: playing ? [14.0, 7, 18][index] : [7.0, 16, 11][index])
                    }
                }
                .frame(width: 14, height: 22)
                .motion(Motion.control, value: playing)
                .accessibilityHidden(true)
                Text(personality.workingWords[line % personality.workingWords.count] + "…")
                    .font(.serif(size, .regular).italic())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                line += 1
                playing = true
            } label: {
                Label("Another working line", systemImage: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent).padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onChange(of: personality) { _, _ in line = 0 }
        .task(id: line) {
            guard playing else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            playing = false
        }
    }
}
