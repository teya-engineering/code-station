import SwiftUI

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    let skills: SkillsManager
    // Where to land when another sheet sends the person straight to one setting.
    var initialTarget: SettingsSearchTarget? = nil

    @State private var reviewingOldSessions = false
    @State private var showingLog = false
    @State private var tab = SettingsTab.general
    @State private var searchText = ""
    @State private var searchTarget: SettingsSearchTarget?
    @State private var searchResultID: String?
    @State private var searchedAgent: AgentKind?
    @State private var bots = BotSettingsFlow()
    @State private var note = TransientNote()
    @State private var appearanceBeforeReset: AppearanceSettings?
    @State private var openInChanges = 0
    @State private var secondOpinion = Preferences.secondOpinionDefaults()
    @State private var secondOpinionBeforeReset: SecondOpinionDefaults?
    @FocusState private var searchFocused: Bool
    // Ties the seat under the chosen pane to whichever row holds it, so picking another
    // pane slides the same shape down the list instead of redrawing it there.
    @Namespace private var paneSeat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                navigation
                if tab == .appearance && bots.isPresented {
                    BotSettingsView(flow: bots) {
                        navigate(to: .appearance)
                    }
                    .transition(.headerPage(reduceMotion: reduceMotion))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: Space.xl) {
                                paneHeading
                                tabContent
                            }
                            .padding(Space.xxxl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                        .id(tab)
                        .transition(.headerPage(reduceMotion: reduceMotion))
                        .onChange(of: searchTarget) { _, target in
                            guard let target else { return }
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                    }
                    .transition(.headerPage(reduceMotion: reduceMotion))
                }
            }
            .environment(\.settingsNote, ExternalNote { text, icon in showNote(text, icon: icon) })
            if bots.draft == nil { settingsFooter }
        }
        .frame(width: 960, height: 680)
        .background(Theme.background)
        .interactiveDismissDisabled(bots.draft?.isDirty == true)
        .onAppear {
            loginItem.refresh()
            if let initialTarget {
                // A link from elsewhere in the app names a setting, not a tab, so it keeps
                // working when the setting moves to another tab.
                if let entry = SettingsSearchIndex.entries.first(where: { $0.target == initialTarget }) {
                    tab = entry.tab
                }
                searchTarget = initialTarget
            }
        }
        .onChange(of: secondOpinion) { _, defaults in Preferences.setSecondOpinionDefaults(defaults) }
        .sheet(isPresented: $reviewingOldSessions) {
            OldSessionsView(sessions: OldSessions.reviewable(rule: settings.cleanupRule,
                                                            store: store, runner: runner))
                .appOverlays()
        }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
        .headerNote(note, top: Theme.headerHeight + 8, trailing: Space.xxl)
    }

    private func showNote(_ text: String, icon: String) {
        note.show(text, icon: icon)
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            AppMark()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("Settings")
                .font(Typography.title)
            Spacer(minLength: 0)
            Text("Teya Code Station")
                .font(Typography.detail.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xxl)
        .headerBand()
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.detail)
                    .focused($searchFocused)
                    .onChange(of: searchText) { _, query in
                        selectFirstSearchResult(for: query)
                    }
                if searchText.isEmpty {
                    Text("⌘F")
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        searchText = ""
                        searchTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.md)
            .fieldSurface(cornerRadius: Radius.card)

            Button { searchFocused = true } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            if searchText.isBlank {
                VStack(spacing: Space.xs) {
                    ForEach(SettingsTab.allCases, id: \.self) { choice in
                        SettingsNavigationItem(
                            title: choice.title,
                            symbol: choice.symbol,
                            selected: tab == choice,
                            seat: paneSeat) {
                                navigate(to: choice)
                            }
                    }
                }
            } else if searchResults.isEmpty {
                Text("No settings found. Try ‘cursor’, ‘theme’, or ‘text’.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.md)
            } else {
                ScrollView {
                    VStack(spacing: Space.xs) {
                        ForEach(searchResults) { result in
                            SettingsSearchResultItem(
                                result: result,
                                selected: searchResultID == result.id) {
                                    select(result)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 16)
        }
        .padding(Space.lg)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    // A pane is swapped for another rather than redrawn in place, so the change is made
    // where the animation can see both sides of it.
    private func show(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.reveal, change)
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchIndex.results(for: searchText)
    }

    private func selectFirstSearchResult(for query: String) {
        guard let result = SettingsSearchIndex.results(for: query).first else {
            searchTarget = nil
            searchResultID = nil
            return
        }
        select(result)
    }

    private func select(_ result: SettingsSearchResult) {
        bots.leave(using: dialogs) {
            show {
                tab = result.tab
                bots.isPresented = result.target == .appearanceDefaultBot
            }
            searchTarget = result.target
            searchResultID = result.id
            searchedAgent = result.agent
        }
    }

    private func navigate(to destination: SettingsTab) {
        bots.leave(using: dialogs) {
            show { tab = destination; bots.isPresented = false }
            searchTarget = nil
        }
    }

    private func resetAppearance() {
        appearanceBeforeReset = settings.appearanceSettings
        settings.resetAppearance()
    }

    private func undoAppearanceReset() {
        guard let previous = appearanceBeforeReset else { return }
        settings.appearanceSettings = previous
        appearanceBeforeReset = nil
    }

    private func resetSecondOpinion() {
        secondOpinionBeforeReset = secondOpinion
        secondOpinion = SecondOpinionDefaults()
        showNote("Second opinion reset", icon: "arrow.counterclockwise")
    }

    private var paneHeading: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(tab.title)
                .font(tab == .appearance ? .logo(26) : Typography.display)
            Text(tab.note)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsFooter: some View {
        SheetFooter(dismiss: { bots.leave(using: dialogs) { dismiss() } }) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 7, height: 7)
                .background(Circle()
                    .fill(Theme.dotOn.opacity(0.12))
                    .frame(width: 13, height: 13))
                .accessibilityHidden(true)
            Text("Changes save automatically")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            if tab == .appearance && !bots.isPresented {
                InlineLink(title: "Reset Appearance", action: resetAppearance)
                    .padding(.leading, Space.sm)
                if appearanceBeforeReset != nil { InlineLink(title: "Undo reset", action: undoAppearanceReset) }
            }
            if tab == .secondOpinion {
                HStack(spacing: Space.md) {
                    InlineLink(title: "Reset Second opinion", action: resetSecondOpinion)
                    if let previous = secondOpinionBeforeReset {
                        InlineLink(title: "Undo reset", action: {
                            secondOpinion = previous
                            secondOpinionBeforeReset = nil
                        })
                        .transition(reduceMotion ? .opacity : .fadeIn)
                    }
                }
                .padding(.leading, Space.sm)
                .motion(Motion.reveal, value: secondOpinionBeforeReset != nil)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: Space.xxl) {
                system.id(SettingsSearchTarget.generalSystem.id)
                sidebar.id(SettingsSearchTarget.generalSidebar.id)
                skillRefresh.id(SettingsSearchTarget.generalSkills.id)
                oldSessions.id(SettingsSearchTarget.generalOldSessions.id)
                orphanedWorktrees.id(SettingsSearchTarget.generalOrphanedWorktrees.id)
                statsRetention.id(SettingsSearchTarget.generalStats.id)
            }
        case .sessions:
            VStack(alignment: .leading, spacing: Space.xxl) {
                midTurnPrompts.id(SettingsSearchTarget.sessionsMidTurnPrompts.id)
                recaps.id(SettingsSearchTarget.sessionsRecaps.id)
                finishedSound.id(SettingsSearchTarget.sessionsSound.id)
                sessionMemory.id(SettingsSearchTarget.sessionsMemory.id)
            }
        case .appearance:
            VStack(alignment: .leading, spacing: Space.xxl) {
                appearance.id(SettingsSearchTarget.appearanceTheme.id)
                headerButtons.id(SettingsSearchTarget.appearanceHeaderButtons.id)
                BotSettingsEntry {
                    show { bots.isPresented = true }
                }
                .id(SettingsSearchTarget.appearanceDefaultBot.id)
            }
        case .keyboard:
            KeyboardSettingsView().id(SettingsSearchTarget.keyboardShortcuts.id)
        case .agents:
            AgentSettingsView(selectedAgent: runner.catalog.agent,
                              requestedAgent: searchedAgent)
        case .secondOpinion:
            SecondOpinionSettingsView(defaults: $secondOpinion)
        case .mobile:
            mobileAccess
        case .advanced:
            VStack(alignment: .leading, spacing: Space.xxl) {
                SiteConfigurationSection(skills: skills)
                ChoiceBlock("DIAGNOSTICS") {
                    SettingsCard {
                        log
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.lg)
                    }
                }
                .id(SettingsSearchTarget.advancedSessionLog.id)
            }
        }
    }

    private var sidebar: some View {
        ChoiceBlock("SIDEBAR") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    settingCopy(
                        title: "Sessions shown",
                        detail: "How many recent sessions each project and workspace lists before See more.")
                    Spacer(minLength: 0)
                    OptionMenu(value: "\(settings.sidebarSessionLimit)") {
                        SidebarSessionVisibility.limitRange.map { limit in
                            .item("\(limit)", checked: settings.sidebarSessionLimit == limit) {
                                settings.sidebarSessionLimit = limit
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Sessions shown per sidebar list: \(settings.sidebarSessionLimit)")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    private var recaps: some View {
        @Bindable var settings = settings
        return ChoiceBlock("WHEN A TURN ENDS") {
            SettingsCard {
                SettingsToggleRow(
                    "Automatic session recaps",
                    detail: "Creates a short recap after a turn finishes while you are in another session or app. You can still request one manually when this is off.",
                    isOn: $settings.sessionRecapsEnabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
            SettingsCard {
                SettingsToggleRow(
                    "Automatic session titles",
                    detail: "Summarises the conversation into a short title after the first turn finishes. You can still regenerate a title from the session's right-click menu when this is off.",
                    isOn: $settings.sessionTitlesEnabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
            .id(SettingsSearchTarget.sessionsTitles.id)
            SettingsCard {
                SettingsToggleRow(
                    "Suggest the next prompt",
                    detail: "Offers a likely next prompt above the composer once a turn ends. Claude Code predicts one as part of the turn. Codex and Copilot cannot, so they are asked in a short separate run that costs a little on every turn.",
                    isOn: $settings.promptSuggestionsEnabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
            .id(SettingsSearchTarget.sessionsSuggestions.id)
        }
    }

    // Return follows this. A queued prompt can still be steered from its row.
    private var midTurnPrompts: some View {
        ChoiceBlock("PROMPTS DURING A TURN") {
            SettingsCard {
                OptionRow(
                    title: "Steer the running turn",
                    detail: "The agent reads the prompt at its next step. Copilot cannot take a prompt mid-turn, so it always queues.",
                    selected: settings.midTurnPromptDelivery == .now) {
                        settings.midTurnPromptDelivery = .now
                }

                SettingsRowDivider()

                OptionRow(
                    title: "Queue it for when the turn ends",
                    detail: "The prompt waits above the composer and runs as a turn of its own. Steer now on a queued prompt sends it into the running turn.",
                    selected: settings.midTurnPromptDelivery == .afterTurn) {
                        settings.midTurnPromptDelivery = .afterTurn
                }
            }
        }
    }

    // Picking a sound plays it, so the list can be walked until one is right without a
    // separate preview button next to it.
    private var finishedSound: some View {
        ChoiceBlock("SOUND") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    settingCopy(
                        title: "When a session finishes",
                        detail: "Plays once a turn ends, whether or not you are looking at that session.")
                    Spacer(minLength: 0)
                    OptionMenu(value: settings.sessionFinishedSound.title) {
                        SessionSound.allCases.map { sound in
                            .item(sound.title,
                                  checked: settings.sessionFinishedSound == sound) {
                                settings.sessionFinishedSound = sound
                                sound.play()
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Sound when a session finishes: \(settings.sessionFinishedSound.title)")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    private var oldSessions: some View {
        OldSessionsSettings(review: { reviewingOldSessions = true })
    }

    private var orphanedWorktrees: some View {
        @Bindable var settings = settings
        return ChoiceBlock("ORPHANED WORKTREES") {
            SettingsCard {
                SettingsToggleRow(
                    "Treat them like old sessions",
                    detail: "Checkouts no session owns go with the same countdown when they have no changes. One with uncommitted changes waits for your OK instead of being pruned.",
                    isOn: $settings.sweepsOrphanedWorktrees)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
        }
    }

    private var statsRetention: some View {
        StatsSettings()
    }

    private var sessionMemory: some View {
        let limit = settings.sessionMemoryLimit
        return ChoiceBlock("SESSION MEMORY") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    settingCopy(
                        title: "Stop a turn after it uses",
                        detail: limit.detail().map {
                            "Counted across the agent and everything it starts. Automatic is a quarter of this Mac's memory, currently \($0)."
                        } ?? "Counted across the agent and everything it starts. Raise this for work that needs a large build, lower it to keep more of the Mac free.")
                    Spacer(minLength: 0)
                    OptionMenu(value: limit.title) {
                        SessionMemoryLimit.choices().map { choice in
                            .item(choice.title, checked: limit == choice) {
                                settings.sessionMemoryLimit = choice
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Session memory limit: \(limit.title)")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    private var skillRefresh: some View {
        ChoiceBlock("SKILLS") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    settingCopy(
                        title: "Refresh the skills list",
                        detail: "Checks the marketplace for new versions. You can still refresh it from Skills at any time.")
                    Spacer(minLength: 0)
                    OptionMenu(value: settings.skillsRefreshInterval.title) {
                        SkillsRefreshInterval.allCases.map { interval in
                            .item(interval.title,
                                  checked: settings.skillsRefreshInterval == interval) {
                                settings.skillsRefreshInterval = interval
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    private var appearance: some View {
        ChoiceBlock("APPEARANCE") {
            SettingsCard {
                HStack(alignment: .center, spacing: Space.xxl) {
                    settingCopy(
                        title: "Theme",
                        detail: "Follow macOS or keep the app in one appearance.")
                        .frame(width: Self.pillRowCopyWidth, alignment: .leading)

                    HStack(spacing: Space.md) {
                        ForEach(Appearance.allCases) { choice in
                            SettingsThemeChoice(
                                appearance: choice,
                                selected: settings.appearance == choice) {
                                    settings.appearance = choice
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(Space.lg)

                SettingsRowDivider()
                sunlight.id(SettingsSearchTarget.appearanceSunlight.id)
            }

            CursorEffectsSection()
                .id(SettingsSearchTarget.appearanceCursorEffects.id)

            SettingsCard {
                HStack(alignment: .center, spacing: Space.xxl) {
                    settingCopy(
                        title: "Session text",
                        detail: "Changes transcripts, diffs, tool output, and terminals.")
                        .frame(width: Self.pillRowCopyWidth, alignment: .leading)

                    Spacer(minLength: 0)

                    Text("Aa")
                        .font(.serif(22 * settings.textSize.scale, .regular))
                        .frame(width: 36)
                        .accessibilityLabel("Text size preview: \(settings.textSize.label)")
                    HStack(spacing: Space.xs) {
                        ForEach(TextSize.allCases) { size in
                            ChoicePill(title: size.label, selected: settings.textSize == size) {
                                settings.textSize = size
                            }
                            .accessibilityLabel("Session text size: \(size.label)")
                            .accessibilityValue(settings.textSize == size ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(Space.lg)
                .id(SettingsSearchTarget.appearanceText.id)

                SettingsRowDivider()

                HStack(alignment: .center, spacing: Space.xxl) {
                    settingCopy(
                        title: "Your messages",
                        detail: "The colour behind what you send in a session.")
                        .frame(width: Self.pillRowCopyWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: Space.lg) {
                        MessageColourPicker(selection: settings.messageColour,
                                            projectTints: previewProjectTints) { colour in
                            settings.messageColour = colour
                        }
                        messageColourNote
                    }
                }
                .padding(Space.lg)
                .id(SettingsSearchTarget.appearanceMessages.id)

                SettingsRowDivider()
                TimestampSettingsRow().id(SettingsSearchTarget.appearanceTimestamps.id)

                SettingsRowDivider()
                sidebarIcons.id(SettingsSearchTarget.appearanceSidebarIcons.id)
            }
        }
    }

    // Sunlight sits on top of whichever appearance is chosen rather than being one, so a
    // dark or light choice is never overridden by the time of day. The warmth slider only
    // shows while it is on, and holding the slider shows the night colour on the window
    // itself, whatever the hour.
    private var sunlight: some View {
        @Bindable var settings = settings
        return VStack(spacing: 0) {
            SettingsToggleRow(
                "Sunlight",
                detail: "Warms the window the way evening light does, easier on the eyes than a cold white screen.",
                isOn: $settings.sunlightEnabled)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)

            if settings.sunlightEnabled {
                HStack(alignment: .center, spacing: Space.xxl) {
                    settingCopy(
                        title: "When",
                        detail: "Follow the sun where you are, or keep the warmth on all day.")
                        .frame(width: Self.pillRowCopyWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: Space.xs) {
                        ForEach(SunlightMode.allCases) { mode in
                            ChoicePill(title: mode.label, selected: settings.sunlightMode == mode) {
                                settings.sunlightMode = mode
                            }
                            .accessibilityLabel("Sunlight: \(mode.label)")
                            .accessibilityValue(settings.sunlightMode == mode ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
                .transition(reduceMotion ? .opacity : .fadeIn)

                HStack(alignment: .center, spacing: Space.xxl) {
                    settingCopy(
                        title: "Warmth",
                        detail: settings.sunlightMode == .fixed
                            ? "The colour the window keeps."
                            : "The colour the window reaches at night. Hold the slider to see it now.")
                        .frame(width: Self.pillRowCopyWidth, alignment: .leading)

                    AppSlider(value: $settings.sunlightNightKelvin,
                              range: Sunlight.nightRange,
                              step: 100,
                              track: AnyShapeStyle(Self.warmthTrack),
                              label: "Sunlight warmth",
                              readout: { "\(Sunlight.name(for: $0)), \(Int($0)) K" },
                              onEditingChanged: { settings.sunlightPreviewing = $0 })

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Sunlight.name(for: settings.sunlightNightKelvin))
                            .font(Typography.label)
                        Text("\(Int(settings.sunlightNightKelvin)) K")
                            .font(Font.mono(Typography.Size.micro))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 72, alignment: .trailing)
                    .contentTransition(.numericText())
                    .motion(Motion.control, value: settings.sunlightNightKelvin)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
                .transition(reduceMotion ? .opacity : .fadeIn)
            }
        }
        .motion(Motion.reveal, value: settings.sunlightEnabled)
        .motion(Motion.control, value: settings.sunlightMode)
    }

    // The track runs from candlelight to daylight, the colours the slider chooses between.
    private static let warmthTrack: LinearGradient = {
        let stops = stride(from: Sunlight.nightRange.lowerBound, through: Sunlight.nightRange.upperBound, by: 600)
            .map { kelvin -> Gradient.Stop in
                let tint = SunlightTint(kelvin: kelvin)
                let fraction = (kelvin - Sunlight.nightRange.lowerBound)
                    / (Sunlight.nightRange.upperBound - Sunlight.nightRange.lowerBound)
                return Gradient.Stop(color: Color(red: tint.red, green: tint.green, blue: tint.blue),
                                     location: fraction)
            }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }()

    // The bubble colours the sample projects would get, read the same way the sidebar
    // reads them, so the picker changes with the icon style.
    private var previewProjectTints: [Theme.ProjectTint] {
        Self.previewProjects.map { project in
            SidebarAvatar(subject: .project, id: project.id).identityTint(
                iconSet: settings.sidebarIconSet,
                style: settings.diceBearAvatarStyle,
                name: project.name,
                monogramTint: Theme.projectTint(for: project.name))
        }
    }

    private var messageColourNote: some View {
        HStack(alignment: .top, spacing: Space.md) {
            if settings.messageColour == .projectIcon {
                HStack(spacing: Space.xxs) {
                    ForEach(Self.previewProjects) { project in
                        SidebarIdentityTile(
                            avatar: SidebarAvatar(subject: .project, id: project.id),
                            name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 16)
                    }
                }
                .padding(.top, 1)
                .accessibilityHidden(true)

                Text("Your messages stay Stone, with a bar in the colour of the project's \(Text("sidebar icon").fontWeight(.semibold).foregroundStyle(.primary)) on the side you write from. Switching icon style changes the bar too.")
            } else {
                Text("Every session uses \(Text(settings.messageColour.label).fontWeight(.semibold).foregroundStyle(.primary)), whatever the project.")
            }
        }
        .font(Typography.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: Radius.card, border: Theme.settingsHairline)
        .accessibilityElement(children: .combine)
    }

    private var headerButtons: some View {
        ChoiceBlock("HEADER BUTTONS") {
            SettingsCard {
                ForEach(Array(HeaderButton.allCases.enumerated()), id: \.element) { index, button in
                    if index > 0 { SettingsRowDivider() }
                    HStack(spacing: Space.lg) {
                        Image(systemName: button.icon)
                            .font(Typography.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .surface(Theme.sunken, cornerRadius: Radius.control, border: Theme.settingsHairline)
                            .accessibilityHidden(true)
                        SettingsToggleRow(
                            button.title,
                            detail: button.detail,
                            isOn: Binding(get: { settings.shows(button) },
                                          set: { settings.setShows($0, button) }))
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
                }
            }
        }
    }

    private var sidebarIcons: some View {
        HStack(spacing: Space.xxl) {
            settingCopy(title: "Sidebar icons", detail: "Give projects a distinct, recognisable look.")
                .frame(width: Self.pillRowCopyWidth, alignment: .leading)
            HStack(spacing: Space.lg) {
                ForEach(Self.previewProjects.prefix(3)) { project in
                    VStack(spacing: Space.xs) {
                        SidebarIdentityTile(avatar: SidebarAvatar(subject: .project, id: project.id),
                                            name: project.name, tint: Theme.projectTint(for: project.name), side: 26)
                        Text(project.name).font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidebar icon preview")
            .accessibilityValue(sidebarIconStyleLabel)
            Spacer(minLength: 0)
            OptionMenu(value: sidebarIconStyleLabel) { sidebarIconStyleMenu }
                .accessibilityLabel("Sidebar icon style: \(sidebarIconStyleLabel)")
        }
        .padding(Space.lg)
    }

    private var sidebarIconStyleLabel: String {
        switch settings.sidebarIconSet {
        case .monograms: "Monogram"
        case .diceBear: settings.diceBearAvatarStyle.label
        }
    }

    private var sidebarIconStyleMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Monogram", image: sidebarIconMonogramImage, imageShape: .tile,
                  checked: settings.sidebarIconSet == .monograms) {
                settings.sidebarIconSet = .monograms
            },
        ]
        entries.append(contentsOf:
            DiceBearAvatarStyle.allCases.map { style in
                .item(style.label,
                      image: SidebarAvatar.preview.artworkImage(style: style),
                      imageShape: .tile,
                      checked: settings.sidebarIconSet == .diceBear
                        && settings.diceBearAvatarStyle == style) {
                    settings.diceBearAvatarStyle = style
                    settings.sidebarIconSet = .diceBear
                }
            })
        return entries
    }

    private var sidebarIconMonogramImage: NSImage? {
        let name = "atlas-web"
        let renderer = ImageRenderer(content: ProjectTileView(
            name: name,
            tint: Theme.projectTint(for: name),
            side: 22))
        renderer.scale = 2
        return renderer.nsImage
    }

    // Fixed examples keep repository names and paths out of settings screenshots.
    private static let previewProjects = [
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000001")!,
                name: "atlas-web", path: "~/Developer/atlas-web"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000002")!,
                name: "orbit-api", path: "~/Developer/orbit-api"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000003")!,
                name: "harbor-mobile", path: "~/Developer/harbor-mobile"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000004")!,
                name: "summit-infra", path: "~/Developer/summit-infra"),
    ]

    // MARK: - System

    private var system: some View {
        ChoiceBlock("SYSTEM") {
            SettingsCard {
                terminal
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
                SettingsRowDivider()
                openIn
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
                SettingsRowDivider()
                startAtLogin
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
        }
    }

    private var terminal: some View {
        // Reading the stored choice here is what ties this row to the setting, so the words
        // change the moment a different terminal is picked.
        let inDrawer = settings.opensTerminalInDrawer
        let value = inDrawer ? SystemTerminal.drawerName : SystemTerminal.appName

        return HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Terminal")
                    .font(Typography.body.weight(.semibold))
                Text(inDrawer
                     ? "The Terminal button offers a shell in the drawer and one in a window of its own. The drawer is named first, and a window opens in \(SystemTerminal.appName), the app macOS hands shell scripts. Pick an app to name it first instead."
                     : "The Terminal button offers a shell in the drawer and one in a window of its own. \(value) is named first, and is where a window opens.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            OptionMenu(value: value) { terminalMenu }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Terminal: \(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(SystemTerminal.drawerName,
                  icon: "terminal",
                  checked: settings.opensTerminalInDrawer,
                  subtitle: "A shell in the drawer, beside what you were reading.") {
                settings.terminalBundleID = nil
            },
            .separator
        ]
        entries.append(contentsOf: SystemTerminal.installed.compactMap { url in
            guard let id = SystemTerminal.bundleID(of: url) else { return nil }
            return .item(SystemTerminal.name(of: url),
                         image: NSWorkspace.shared.icon(forFile: url.path),
                         checked: settings.terminalBundleID == id) {
                settings.terminalBundleID = id
            }
        })
        entries.append(.separator)
        entries.append(.item("Choose…", icon: "folder") { chooseTerminal() })
        return entries
    }

    // The list only holds apps that say they run shell scripts, and not every terminal
    // says so, so there is a way to name one the list never offered.
    private func chooseTerminal() {
        guard let url = FilePicker.chooseFile(prompt: "Choose",
                                              message: "Pick the terminal to open a shell in.",
                                              types: [.application],
                                              directory: URL(fileURLWithPath: "/Applications"))
        else { return }

        guard let id = SystemTerminal.bundleID(of: url) else {
            dialogs.show(.notice(
                "Could not use that app",
                message: "\(SystemTerminal.name(of: url)) does not look like an application macOS can open."))
            return
        }
        settings.terminalBundleID = id
    }

    private var openIn: some View {
        // WorktreeOpener is not observed, so this count is what redraws the row after a change.
        let _ = openInChanges
        let value = WorktreeOpener.current?.name ?? "Finder"
        let added = WorktreeOpener.addedApps

        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Open in")
                        .font(Typography.body.weight(.semibold))
                    Text("The app a session's Open in button sends its folder to. Editors on this Mac are listed on their own. Add any other app to list it too.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                OptionMenu(value: value) { openInMenu }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Open in: \(value)")
            }
            ForEach(added) { app in
                HStack(spacing: Space.md) {
                    Image(nsImage: WorktreeOpener.icon(for: app))
                        .resizable()
                        .frame(width: ControlHeight.xs, height: ControlHeight.xs)
                        .accessibilityHidden(true)
                    Text(app.name)
                        .font(Typography.body)
                    Spacer(minLength: 0)
                    InlineLink(title: "Remove", tint: Theme.deletion) {
                        WorktreeOpener.remove(app.bundleID)
                        openInChanges += 1
                    }
                }
                .transition(.fold)
            }
        }
        .motion(Motion.reveal, value: added.map(\.id))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openInMenu: [MenuEntry] {
        let current = WorktreeOpener.current

        return WorktreeOpener.apps.map { app in
            .item(app.name, image: WorktreeOpener.icon(for: app), imageShape: .tile,
                  checked: app == current) {
                WorktreeOpener.choose(app)
                openInChanges += 1
            }
        } + [
            .separator,
            .item("Add app…", icon: "plus") {
                if WorktreeOpener.pickApp(dialogs: dialogs) != nil { openInChanges += 1 }
            },
        ]
    }

    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SettingsToggleRow(
                "Start at login",
                detail: "Opens Teya Code Station when you log in, so sessions are there waiting.",
                isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))

            if let failure = loginItem.failure {
                Text(failure)
                    .font(Typography.detail)
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mobileAccess: some View {
        @Bindable var settings = settings
        let lifetime = settings.mobilePairingLifetime
        return VStack(alignment: .leading, spacing: Space.xxl) {
            ChoiceBlock("MOBILE ACCESS") {
                SettingsCard {
                    SettingsToggleRow(
                        "Mobile access",
                        detail: "Puts a QR code on Home. A phone on the same trusted Wi-Fi that scans it can read and run every session in every project.",
                        isOn: $settings.mobileAccessEnabled)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.lg)
                }
            }
            .id(SettingsSearchTarget.mobileAccess.id)

            ChoiceBlock("PAIRING") {
                SettingsCard {
                    HStack(alignment: .top, spacing: Space.lg) {
                        settingCopy(
                            title: "Keep a code working for",
                            detail: "How long a code lasts with no phone on it, counted from when you start sharing or the phone leaves. A connected phone is never cut off. Locking the phone usually counts as leaving.")
                        Spacer(minLength: 0)
                        OptionMenu(value: lifetime.title) {
                            MobilePairingLifetime.choices.map { choice in
                                .item(choice.title, checked: lifetime == choice) {
                                    settings.mobilePairingLifetime = choice
                                }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Keep a code working for: \(lifetime.title)")
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
                }
            }
            .id(SettingsSearchTarget.mobilePairingLifetime.id)
        }
    }

    private func settingCopy(title: String, detail: String) -> some View {
        Self.settingCopy(title: title, detail: detail)
    }

    // The width of the words beside a row of pills or swatches. Held to one width so the
    // controls on every such row start on the same line, and they get the rest.
    static let pillRowCopyWidth: CGFloat = 160

    // A setting's name over the sentence that says what it changes, shared with the rows
    // that live in views of their own.
    static func settingCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(Typography.body.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // A turn that stops moving looks the same as one that is working, and the transcript
    // keeps no record of the difference. This is where that record is.
    private var log: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Session log")
                    .font(Typography.body.weight(.semibold))
                Text("Every line Claude Code sent, and what the app did with it. Worth opening when a turn seems stuck.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            InlineLink(title: "Open") { showingLog = true }
            InlineLink(title: "Reveal") {
                SessionLog.revealInFinder()
                showNote("Revealed the session log in Finder", icon: "folder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    // Lets a pane deep inside Settings leave a note in the window's corner when a click
    // does its work outside the window, such as revealing a file in Finder.
    @Entry var settingsNote = ExternalNote()
}
