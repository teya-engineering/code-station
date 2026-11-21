import AppKit
import SwiftUI

// The composer under the transcript and the rows that sit on top of it.
extension SessionView {
    // Says what Return will do with the prompt.
    func placeholder(state: SessionState, agent: AgentKind) -> String {
        switch state {
        case .waiting: "Say what to do next…"
        case _ where state.isBusy:
            runner.canSteer(sessionID) && appSettings.midTurnPromptDelivery == .now
                ? "Steer the running turn…" : "Queue what comes next…"
        default: "Ask \(agent.title) anything…"
        }
    }

    func composer(session: ChatSession, project: Project, blocked: Bool) -> some View {
        let state = runner.state(sessionID)
        return Composer(sessionID: sessionID,
                        agent: session.agent,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: placeholder(state: state, agent: session.agent),
                        onOversizedPaste: offerTextFile,
                        onRecallUp: { runner.recallEarlier(sessionID) },
                        onRecallDown: { runner.recallLater(sessionID) },
                        onSend: {
                            promptSentAt = .now
                            transcriptPinnedToBottom = true
                            transcriptScrollRequest += 1
                        },
                        onSuggestionKey: { suggestionKey($0, blocked: blocked) },
                        dictates: true,
                        above: {
                            snoozeStrip(session)
                            runChoices(session, project: project)
                            contextNudge(session)
                            aside(directory: session.worktreePath ?? project.path)
                            promptSuggestion(busy: state.isBusy, blocked: blocked)
                            SessionQueueStrip(sessionID: sessionID, busy: state.isBusy,
                                              blocked: blocked) { composerFocused = true }
                        },
                        accessory: {
                            SessionBotPicker(avatars: appSettings.agentAvatars,
                                             selectedName: botSelection(for: session),
                                             sessionID: sessionID,
                                             size: 22)
                        })
                        .motion(store.isSnoozed(sessionID) ? Motion.reveal : Motion.leave,
                                value: store.isSnoozed(sessionID))
                        .motion(Motion.reveal, value: runner.queued(sessionID).isEmpty)
                        .motion(Motion.reveal, value: runner.asides.aside(sessionID)?.id)
                        .motion(Motion.leave, value: runner.isNudgeDismissed(sessionID))
    }

    // The choices the next turn will run on, on the line the eye is already on when
    // hitting send: the session's fixed agent, its model, and the rest of the run
    // controls. What the session has done and where belongs on the status strip, not
    // here - this line is only ever about what happens next.
    //
    // The saved commands sit at the end of it, behind one Run button, for the same
    // reason. Running the tests for what was just written is the next thing that happens
    // as much as sending another prompt is.
    @ViewBuilder private func runChoices(_ session: ChatSession, project: Project) -> some View {
        HStack(spacing: Space.md) {
            if session.settings?.mcpServersEnabled == false {
                MonoChip(text: "MCP off", size: Typography.Size.caption, bordered: true)
            }
            SessionRunSettingsControls(sessionID: sessionID)
            Spacer(minLength: 12)

            // Ad-hoc tasks run in a private folder the app made for one prompt, so there
            // is nothing there worth saving a command against.
            if project.kind == .project {
                SessionRunButton(session: session, availableWidth: composerBarWidth,
                                 edit: { shortcutEditor = $0 })
            }
        }
        // The command list rises over the transcript, so the row is drawn above it.
        .zIndex(1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerBarWidth = $0 }
    }

    private func botSelection(for session: ChatSession) -> Binding<String> {
        Binding(
            get: {
                AgentAvatarSelection.resolvedName(
                    store.session(sessionID)?.agentAvatarName,
                    availableNames: appSettings.agentAvatars.map { $0.url.lastPathComponent })
            },
            set: { store.setAgentAvatarName($0, for: sessionID) })
    }

    // Manual compaction is a Claude Code action. Clearing remains available for either
    // agent as a deliberate fresh start, even though Codex makes room automatically.
    func contextActions() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if runner.canCompactContext(sessionID) {
            entries.append(.item("Compact context",
                                 subtitle: "Summarises the conversation so far and carries on from it.") {
                confirmCompact()
            })
        }
        if runner.canClearContext(sessionID) {
            entries.append(.item("Clear context",
                                 kind: .destructive,
                                 subtitle: "The next turn starts a fresh conversation in the same folder.") {
                runner.clearContext(sessionID)
            })
        }
        return entries
    }

    // Compacting spends a turn and takes the best part of a minute, which is not what a
    // menu row usually costs, so it is said plainly before it starts.
    private func confirmCompact() {
        dialogs.show(.confirm(
            "Compact this session's context?",
            message: "The agent reads the conversation so far, replaces it with a summary, and carries on from that. It takes a turn of its own - up to a minute - and counts towards what this session has spent.",
            action: "Compact", kind: .primary) {
                runner.compact(sessionID)
            })
    }

    // A session runs into the end of its window mid-thought, and the failure is a turn
    // that will not start rather than anything the meter said. So once the window is
    // nearly full the way out is offered here, on the line above the composer, rather
    // than waiting to be looked for. Codex and Copilot handle this condition through
    // automatic compaction, so only Claude Code needs the interruption.
    @ViewBuilder private func contextNudge(_ session: ChatSession) -> some View {
        let fraction = session.usage?.contextFraction(for: session.agent) ?? 0
        let actions = contextActions()
        if session.agent == .claudeCode,
           fraction >= SessionRunner.nearlyFullContext, !actions.isEmpty,
           !runner.isNudgeDismissed(sessionID) {
            HStack(spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                Text("CONTEXT IS NEARLY FULL · \(Int((fraction * 100).rounded()))%")
                    .font(Typography.caption.weight(.semibold))
                    .kerning(1.2)
                Spacer(minLength: 8)
                if runner.canCompactContext(sessionID) {
                    ActionButton(title: "Compact", tone: .green, height: ControlHeight.sm, size: Typography.Size.detail,
                                 action: confirmCompact)
                        .appTooltip("Summarises the conversation so far and carries on from it.")
                }
                InlineLink(title: "Clear", size: Typography.Size.detail) {
                    runner.clearContext(sessionID)
                }
                .appTooltip("Starts the next turn on a fresh conversation in the same folder.")
                Button { runner.dismissNudge(sessionID) } label: {
                    Image(systemName: "xmark")
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(Space.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .appTooltip("Hide this until the window is dealt with")
            }
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.field, cornerRadius: Radius.control, border: Theme.attention.opacity(0.4))
            .transition(dismissal)
        }
    }

    private func dismissSuggestion() {
        withAnimation(reduceMotion ? nil : Motion.leave) {
            runner.dismissSuggestion(sessionID)
        }
    }

    // The answer to a /btw question. It stays while the session works, since it was
    // asked about the work and does not go stale when the next turn starts.
    @ViewBuilder private func aside(directory: String) -> some View {
        if let aside = runner.asides.aside(sessionID) {
            SessionAsideCard(aside: aside, projectPath: directory, textScale: appSettings.textSize.scale) {
                withAnimation(reduceMotion ? nil : Motion.leave) {
                    runner.asides.dismiss(sessionID)
                }
            }
            .id(aside.id)
            .transition(dismissal)
        }
    }

    // What the agent expects to be asked next. It sits with the other rows about what
    // happens next, and goes as soon as the session starts working again, since a
    // prediction made about a finished turn says nothing about the one now running.
    @ViewBuilder private func promptSuggestion(busy: Bool, blocked: Bool) -> some View {
        if !busy, !blocked, let suggestion = runner.suggestion(sessionID) {
            PromptSuggestionStrip(
                suggestion: suggestion,
                hasDraft: !runner.composer.draft(sessionID).text.isBlank,
                edit: editSuggestion,
                send: sendSuggestion,
                dismiss: dismissSuggestion)
                .transition(dismissal)
        }
    }

    private func editSuggestion() {
        runner.takeSuggestion(sessionID)
        composerFocused = true
    }

    private func sendSuggestion() {
        transcriptPinnedToBottom = true
        transcriptScrollRequest += 1
        runner.sendSuggestion(sessionID)
    }

    // The keys the strip answers, taken only while it is on screen and the cursor is in
    // the composer. Return is deliberately not among them: the key pressed hundreds of
    // times a day keeps meaning "send the draft" and can never be taken by a prediction.
    private func suggestionKey(_ key: SuggestionKey, blocked: Bool) -> Bool {
        guard !blocked, !runner.state(sessionID).isBusy,
              runner.suggestion(sessionID) != nil else { return false }
        switch key {
        case .edit:
            editSuggestion()
        case .send:
            // With words already typed the pill reads Append, so the key that would have
            // sent has nothing to answer and falls through to its usual meaning.
            guard runner.composer.draft(sessionID).text.isBlank else { return false }
            sendSuggestion()
        case .cancel:
            dismissSuggestion()
        }
        return true
    }

    // A snoozed session says so where the next prompt is typed, with the way back.
    @ViewBuilder private func snoozeStrip(_ session: ChatSession) -> some View {
        if let snooze = store.snooze(of: session.id) {
            SessionSnoozeStrip(snooze: snooze) {
                SessionSnoozeMenu.wake(session.id, store: store)
                composerFocused = true
            }
            .transition(dismissal)
        }
    }

    private func offerTextFile(_ text: String) {
        let count = text.count.formatted()
        let limit = ComposerPaste.characterLimit.formatted()
        let message = "This paste has \(count) characters. Pastes are limited to \(limit) characters "
            + "to keep the composer responsive. Would you like to upload it as a text file instead?"
        dialogs.show(.confirm("Text is too long to paste", message: message,
                              action: "Upload as file", kind: .primary) {
            guard let attachment = Attachments.fromPastedText(text) else {
                dialogs.show(.notice("Could not attach the text",
                                     message: "The temporary text file could not be created."))
                return
            }
            runner.composer.attach([attachment], to: sessionID)
            composerFocused = true
        })
    }
}
