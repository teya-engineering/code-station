import Observation
import SwiftUI

// Where a clean up has got to. Kept outside the view so the dialog can ask whether it may
// be dismissed while docker is still pruning.
@MainActor
@Observable
final class DockerCleanUpRun {
    enum Phase { case choosing, running, done }
    enum Step: Equatable { case waiting, running, done, failed(String) }

    var phase = Phase.choosing
    var steps: [DockerCleanUp.Choice: Step] = [:]
    var freed: Int64 = 0

    var isWorking: Bool { phase == .running }

    var failures: [String] {
        steps.values.compactMap { if case .failed(let message) = $0 { message } else { nil } }
    }
}

// The guided `docker system prune`: six choices, each with what it would free, and the
// commands it runs on show. Running it ticks each step and ends with the space freed.
struct DockerCleanUpView: View {
    let plans: (keeping: DockerCleanUp, removing: DockerCleanUp)
    let run: DockerCleanUpRun
    let finished: (Int64) -> Void

    @Environment(DockerService.self) private var docker
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choices = DockerCleanUp.Choice.safe
    @State private var showsCommands = false

    // Removing stopped containers frees what only they were using, so the plan follows
    // that one choice.
    private var plan: DockerCleanUp {
        choices.contains(.stoppedContainers) ? plans.removing : plans.keeping
    }

    private var steps: [DockerCleanUp.Choice] { plan.steps(choices) }
    private var total: Int64 { plan.total(choices) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            HuggingHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(spacing: Space.sm) {
                            ForEach(DockerCleanUp.Choice.allCases, id: \.self) { choice in
                                choiceRow(choice)
                            }
                        }
                        if run.phase == .choosing { notes }
                        if !run.failures.isEmpty { failures }
                    }
                    .padding(Space.xxl)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Divider().overlay(Theme.border)
            footer
        }
        .background(Theme.card)
        .onExitCommand {
            guard !run.isWorking else { return }
            dialogs.dismiss()
            if run.phase == .done { finished(run.freed) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Clean up Docker").font(Typography.display).accessibilityAddTraits(.isHeader)
                Text("Pick what to remove. Anything a running container uses is left alone.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlyphButton(icon: "xmark") {
                dialogs.dismiss()
                if run.phase == .done { finished(run.freed) }
            }
                .disabled(run.isWorking)
                .accessibilityLabel("Close clean up")
        }
        .padding(.top, Space.xl).padding(.leading, Space.xxl).padding(.trailing, Space.xl).padding(.bottom, Space.xl)
    }

    private func choiceRow(_ choice: DockerCleanUp.Choice) -> some View {
        let line = plan.line(choice)
        let picked = DockerCleanUp.effective(choices).contains(choice) && !line.isEmpty
        // Taken along by the prune of every unused image, so it cannot be unticked alone.
        let carried = choice == .untaggedImages && choices.contains(.unusedImages)
        let skipped = run.phase != .choosing && run.steps[choice] == nil
            && !(carried && run.steps[.unusedImages] != nil)
        return Button {
            choices.formSymmetricDifference([choice])
        } label: {
            HStack(alignment: .top, spacing: Space.lg) {
                stepMark(choice, picked: picked)
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    .motion(Motion.pop, value: run.steps[choice])
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        Text(choice.title).font(Typography.body.weight(.semibold))
                        if choice.losesData { DockerBadge(text: "Data loss", tone: .warning) }
                        if choices.contains(.stoppedContainers), line.freedByStopped > 0 {
                            DockerBadge(text: "+\(line.freedByStopped) from stopped containers", tone: .grey)
                                .transition(.opacity)
                        }
                    }
                    Text(choice.detail)
                        .font(Typography.detail)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    Text(line.isEmpty ? "None" : line.bytes > 0 ? DockerSize.text(line.bytes) : " ")
                        .font(Typography.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(line.isEmpty ? Theme.secondaryText : .primary)
                        .contentTransition(.numericText())
                    if !line.isEmpty {
                        Text(line.countText)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(Space.lg)
            .background(picked ? Theme.accent.opacity(0.06) : Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(picked ? Theme.accent.opacity(0.35) : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .disabled(line.isEmpty || carried || run.phase != .choosing)
        .opacity(skipped ? 0.35 : line.isEmpty ? 0.6 : 1)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: picked)
        .motion(Motion.reveal, value: plan.line(choice).freedByStopped)
        .accessibilityLabel("\(choice.title), \(line.isEmpty ? "none" : DockerSize.text(line.bytes))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder private func stepMark(_ choice: DockerCleanUp.Choice, picked: Bool) -> some View {
        let step = choice == .untaggedImages && run.steps[choice] == nil ? run.steps[.unusedImages] : run.steps[choice]
        switch run.phase == .choosing ? nil : step {
        case nil:
            CheckboxMark(isOn: picked)
        case .waiting:
            Circle().stroke(Theme.border, lineWidth: 1.5).frame(width: 14, height: 14)
        case .running:
            LoopSpinner(colour: Theme.accent, size: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.dotOn)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.deletion)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var notes: some View {
        if choices.contains(.unusedVolumes), !plan.line(.unusedVolumes).isEmpty {
            let line = plan.line(.unusedVolumes)
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle.fill").font(Typography.caption)
                Text(volumeWarning(line))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Typography.detail)
            .foregroundStyle(Theme.warningText)
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: Radius.control))
            .padding(.top, Space.lg)
            .transition(.fadeIn)
        }
        HStack(spacing: Space.md) {
            InlineLink(title: showsCommands ? "Hide the commands this runs" : "Show the commands this runs",
                       size: Typography.Size.detail) {
                showsCommands.toggle()
            }
            Spacer(minLength: 8)
            Text("Shared layers can make the space freed a little smaller.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, Space.lg)
        if showsCommands {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if steps.isEmpty {
                    Text("# nothing picked").foregroundStyle(Theme.terminalDim)
                }
                ForEach(steps, id: \.self) { step in
                    (Text("$ ").foregroundStyle(Theme.terminalDim)
                        + Text((["docker"] + step.command).joined(separator: " ")))
                }
            }
            .font(Typography.data)
            .foregroundStyle(Theme.terminalText)
            .textSelection(.enabled)
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.terminal, in: RoundedRectangle(cornerRadius: Radius.control))
            .padding(.top, Space.md)
            .transition(.fadeIn)
        }
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(run.failures, id: \.self) { message in
                Text(message).font(Typography.data).textSelection(.enabled)
            }
        }
        .foregroundStyle(Theme.warningText)
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.top, Space.lg)
    }

    private func volumeWarning(_ line: DockerCleanUp.Line) -> String {
        let them = line.count == 1 ? "it" : "them"
        let named = line.largest.map { ", including \($0)" } ?? ""
        return "\(line.countText) and the data inside \(them) will be gone for good\(named)."
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Group {
                switch run.phase {
                case .choosing:
                    (Text("Frees about ") + Text(DockerSize.text(total)).font(Typography.body.weight(.semibold))
                        .foregroundStyle(.primary))
                case .running:
                    (Text("Freed ") + Text(DockerSize.text(run.freed)).font(Typography.body.weight(.semibold))
                        .foregroundStyle(.primary) + Text(" so far"))
                case .done:
                    (Text("Freed ") + Text(DockerSize.text(run.freed)).font(Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.dotOnText))
                }
            }
            .font(Typography.detail)
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()
            .contentTransition(.numericText())
            .motion(Motion.pop, value: run.freed)
            .motion(Motion.pop, value: total)
            Spacer(minLength: 0)
            switch run.phase {
            case .choosing:
                ActionButton(title: "Cancel", tone: .outlined, keyboardShortcut: .cancelAction) {
                    dialogs.dismiss()
                }
                ActionButton(title: total > 0 ? "Clean up \(DockerSize.text(total))"
                                : steps.isEmpty ? "Nothing to clean" : "Clean up",
                             tone: .danger, keyboardShortcut: .defaultAction, action: start)
                    .disabled(steps.isEmpty)
            case .running:
                ActionButton(title: "Cleaning up…", tone: .danger) {}
                    .disabled(true)
            case .done:
                ActionButton(title: "Done", tone: .dark, keyboardShortcut: .defaultAction) {
                    dialogs.dismiss()
                    finished(run.freed)
                }
            }
        }
        .padding(.vertical, Space.lg).padding(.leading, Space.xxl).padding(.trailing, Space.lg)
        .background(Theme.field)
    }

    // One step at a time, so each line can tick as docker finishes it. Docker says what it
    // reclaimed, and the estimate stands in only when it does not.
    private func start() {
        let steps = steps
        guard !steps.isEmpty else { return }
        let plan = plan
        run.steps = Dictionary(uniqueKeysWithValues: steps.map { ($0, .waiting) })
        run.phase = .running
        Task {
            for step in steps {
                run.steps[step] = .running
                let result = step == .stoppedContainers
                    ? await docker.pruneStoppedContainers()
                    : await docker.prune(step.command)
                if let failure = result.failure {
                    run.steps[step] = .failed(failure)
                } else {
                    run.freed += result.freed ?? plan.line(step).bytes
                    run.steps[step] = .done
                }
            }
            await docker.refresh(sizes: true)
            run.phase = .done
        }
    }
}
