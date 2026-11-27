import Foundation
import Observation

// Everything the switch dialog shows and changes, from the review to the handover. Nothing
// touches the session until the last step, so cancelling or failing leaves it exactly as
// it was, with the note kept for another try.
@MainActor
@Observable
final class AgentSwitchDraft {
    enum Step: Int, CaseIterable, Identifiable, Sendable {
        case save, note, start, read
        var id: Int { rawValue }
    }

    enum Phase: Equatable {
        case review
        case running(Step)
        case failed(Step)
        case finished
    }

    struct Failure: Equatable {
        let title: String
        let message: String
        // What to type to fix it, offered with a copy button.
        let command: String?
    }

    let sessionID: UUID
    let from: AgentKind
    let to: AgentKind
    // The agent ran in this session before, so it resumes its own conversation.
    let returning: Bool
    let fromModelTitle: String
    let fromEffortTitle: String?
    let fromModel: String?
    let fromEffort: String?
    let currentAccess: AgentAccess
    let branch: String?
    let contextWindow: Int?

    var handoff: AgentHandoff = .note
    var note = "" {
        didSet { if !applyingDraft { noteEdited = true } }
    }
    private(set) var noteEdited = false
    private(set) var isDrafting = false
    var model: String? {
        didSet { if oldValue != model { keepEffortValid() } }
    }
    var effort: String?
    var access: AgentAccess

    private(set) var phase: Phase = .review
    private(set) var failure: Failure?
    private(set) var stepSeconds: [Step: Double] = [:]
    private(set) var installedVersion: String?

    let catalog: AgentCatalog
    private let store: ProjectStore
    private let runner: SessionRunner
    private let unseen: [ChatMessage]
    private let projectPath: String
    private let workingDirectory: String?
    private var applyingDraft = false
    private var draftTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    init?(sessionID: UUID, to: AgentKind, store: ProjectStore, runner: SessionRunner) {
        guard let session = store.session(sessionID), session.agent != to else { return nil }
        let catalog = runner.catalog
        let from = session.agent
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.store = store
        self.runner = runner
        self.catalog = catalog
        returning = session.agentsUsed.contains(to)

        let settings = session.settings
        let fromModel = catalog.validModel(settings?.model, for: from)
        self.fromModel = fromModel
        fromModelTitle = fromModel.map { catalog.modelTitle($0) }
            ?? session.usage?.model(for: from).map { ModelChoice.shortName(of: $0) }
            ?? "Default model"
        let fromEffort = catalog.validEffort(settings?.effort ?? catalog.defaults(for: from).effort,
                                             for: from, model: fromModel)
        self.fromEffort = fromEffort
        fromEffortTitle = fromEffort.map { catalog.effortTitle($0, for: from, model: fromModel) }
        currentAccess = AgentAccess.current(for: from, settings: settings,
                                            defaults: catalog.defaults(for: from))
        access = AgentAccess.current(for: from, settings: settings,
                                     defaults: catalog.defaults(for: from)).nearest(on: to)
        branch = session.worktreeBranch
        contextWindow = session.usage.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil }

        let lastRun = session.lastRun(of: to)
        let model = catalog.validModel(lastRun?.model, for: to)
            ?? catalog.validModel(catalog.defaults(for: to).model, for: to)
        self.model = model
        // The level in use carries over when the next agent has it, since that is what the
        // person picked most recently.
        effort = [fromEffort, lastRun?.effort, catalog.defaults(for: to).effort]
            .lazy.compactMap { catalog.validEffort($0, for: to, model: model) }.first

        projectPath = session.worktreePath ?? store.project(session.projectID)?.path ?? ""
        workingDirectory = store.workingDirectories(for: session).first
        unseen = AgentSwitch.unseenMessages(store.transcript(of: sessionID), by: to)
    }

    var effortLevels: [String] {
        catalog.effortOptions(for: to, model: model).compactMap(\.id)
    }

    var modelOptions: [ModelChoice.Option] {
        catalog.modelOptions(for: to).filter { $0.id != nil }
    }

    var warnings: [AgentSwitchWarning] {
        AgentSwitch.warnings(from: from, to: to, currentAccess: currentAccess,
                             newAccess: access, returning: returning)
    }

    var transcriptText: String {
        AgentSwitch.plainTranscript(unseen, agent: from, projectPath: projectPath)
    }

    // What goes over to the next agent in the chosen form, as text.
    var handoffText: String {
        switch handoff {
        case .note: note
        case .transcript: transcriptText
        case .worktree: ""
        }
    }

    var handoffTokens: Int { AgentSwitch.estimatedTokens(handoffText) }

    var handoffShare: Double? {
        guard let contextWindow else { return nil }
        return min(1, Double(handoffTokens) / Double(contextWindow))
    }

    var canStart: Bool {
        guard phase == .review || isFailed else { return false }
        if handoff == .note { return !isDrafting && !note.isBlank }
        return true
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var settingsSummary: String {
        let modelTitle = model.map { catalog.modelTitle($0) } ?? "\(to.title) default model"
        let effortTitle = effort.map { "\(catalog.effortTitle($0, for: to, model: model)) effort" }
        return [modelTitle, effortTitle, access.title].compactMap { $0 }.joined(separator: " · ")
    }

    private func keepEffortValid() {
        effort = catalog.validEffort(effort, for: to, model: model)
            ?? catalog.validEffort(catalog.defaults(for: to).effort, for: to, model: model)
    }

    // MARK: - The note

    // The agent handing over knows the work best, so it is asked to write the note in a
    // throwaway run. When that fails, a plain note built from the transcript stands in,
    // so the dialog always has something to send.
    func draftNote() {
        draftTask?.cancel()
        setNote("")
        noteEdited = false
        isDrafting = true
        let fallback = AgentSwitch.plainNote(unseen, projectPath: projectPath)
        let prompt = AgentSwitch.notePrompt(
            transcript: AgentSwitch.plainTranscript(unseen, agent: from, projectPath: projectPath,
                                                    limit: 40_000),
            from: from, to: to)
        let path = catalog.executable(for: from)
        let directory = workingDirectory
        let agent = from
        let model = from == .codex ? fromModel : nil
        draftTask = Task { [weak self] in
            var written: String?
            if let path, let directory {
                written = await OneShotAgent.ask(
                    agent: agent, at: path, searchPath: ProcessManager.searchPath,
                    workingDirectory: directory, prompt: prompt, model: model,
                    timeout: .seconds(90), purpose: "handoff note")
            }
            guard !Task.isCancelled, let self else { return }
            if !noteEdited { setNote(Self.cleanedNote(written) ?? fallback) }
            isDrafting = false
        }
    }

    private func setNote(_ text: String) {
        applyingDraft = true
        note = text
        applyingDraft = false
    }

    // An agent may wrap the note in a fence or put a line in front of it.
    nonisolated static func cleanedNote(_ text: String?) -> String? {
        guard var note = text?.trimmed, !note.isEmpty else { return nil }
        if note.hasPrefix("```") {
            var lines = note.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines = lines.dropLast() }
            note = lines.joined(separator: "\n").trimmed
        }
        if let heading = note.range(of: "## "), heading.lowerBound != note.startIndex {
            note = String(note[heading.lowerBound...])
        }
        return note.isEmpty ? nil : note
    }

    // MARK: - Handing over

    func start(onFinish: @escaping @MainActor () -> Void) {
        guard canStart else { return }
        failure = nil
        stepSeconds = [:]
        runTask = Task { [weak self] in
            await self?.run()
            if self?.phase == .finished { onFinish() }
        }
    }

    func cancel() {
        runTask?.cancel()
        draftTask?.cancel()
    }

    private func run() async {
        // Save the conversation: a resume id is saved with every turn, so all that is left
        // is to make sure no turn is still writing to it.
        guard await step(.save, {
            guard !self.runner.state(self.sessionID).isBusy else {
                return Failure(title: "\(self.from.title) is working again",
                               message: "A turn started before the switch could go ahead. Nothing changed. Try again once it ends.",
                               command: nil)
            }
            return nil
        }) else { return }

        guard await step(.note, {
            while self.handoff == .note, self.isDrafting, !Task.isCancelled {
                await self.draftTask?.value
            }
            return nil
        }) else { return }

        guard await step(.start, { await self.checkCLI() }) else { return }

        guard await step(.read, {
            self.apply()
            return nil
        }) else { return }
        phase = .finished
    }

    private func step(_ step: Step, _ work: () async -> Failure?) async -> Bool {
        guard !Task.isCancelled else { return false }
        phase = .running(step)
        let started = ContinuousClock.now
        let problem = await work()
        let elapsed = (ContinuousClock.now - started).components
        stepSeconds[step] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard !Task.isCancelled else {
            phase = .review
            return false
        }
        if let problem {
            failure = problem
            phase = .failed(step)
            return false
        }
        return true
    }

    private func checkCLI() async -> Failure? {
        catalog.refreshAvailableAgents()
        guard let path = catalog.executable(for: to) else {
            return Failure(title: "\(to.title) is not installed",
                           message: "Code Station could not find \"\(to.command)\" on PATH. Install it, then try again. Nothing changed: you are still in \(from.title), and the note is kept.",
                           command: to.installHint)
        }
        let output = await cliVersion(at: path, searchPath: ProcessManager.searchPath)
        installedVersion = output.flatMap { AgentSwitch.versionNumber(from: $0, agent: to) }
        if let version = installedVersion, to.isOutdated(version) == true {
            return Failure(title: "\(to.title) \(version) is too old for Code Station",
                           message: "Code Station needs \(to.minimumVersion) or newer. Update it, then try again. Nothing changed: you are still in \(from.title), and the note is kept.",
                           command: to.installHint)
        }
        return nil
    }

    // The only step that changes the session. The marker goes in first, so the new
    // agent's first reply lands under it.
    private func apply() {
        guard let session = store.session(sessionID) else { return }
        var settings = session.settings ?? SessionSettings()
        settings.model = model
        settings.effort = effort
        access.apply(to: &settings)
        store.switchAgent(sessionID, to: to, settings: settings,
                          record: AgentSwitchRecord(from: from, to: to, date: .now,
                                                    model: fromModel, effort: fromEffort))
        var marker = ChatMessage(role: .system, text: "Switched from \(from.title) to \(to.title). \(settingsSummary).")
        marker.marker = SettingsMarker(kind: .agent, agent: to, from: from, value: to.title,
                                         settings: settingsSummary, handoff: handoff,
                                         note: handoff == .note ? note : nil)
        store.append(marker, to: sessionID)
        if let prompt = AgentSwitch.handoffPrompt(handoff, text: handoffText, from: from, to: to,
                                                  returning: returning) {
            runner.sendAppCommand(prompt, sessionID: sessionID)
        }
    }
}
