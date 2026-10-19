import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The troubleshoot form, as the GUI's Troubleshoot tab and its "Agent diagnosis" sheet
// ask it: the problem, the environment, when it happened, evidence by path, the skills
// to load and whether MCP servers are in play. The tab asks it of the session it is on;
// the sheet (Tools → Troubleshoot) also asks where the diagnosis runs and on which agent.
// Several evidence paths or skills are separated with commas.
enum TroubleshootForm {
    // Where a new diagnosis can run: a project or a workspace, by its sidebar name.
    struct Place {
        let name: String
        let target: RemoteDiagnosis.Target
    }

    // The skills typed last, which the next form starts from, as the GUI remembers them.
    @MainActor static var lastSkills = ""

    @MainActor
    static func form(options: RemoteDiagnosisOptions, places: [Place]? = nil) -> FormView {
        var fields: [FormView.Field] = []
        if let places {
            fields.append(.choice("place", "Run in", places.map(\.name)))
            fields.append(.choice("agent", "Agent", AgentKind.allCases.map(\.title),
                                  selected: AgentKind.allCases.firstIndex(of: options.agent) ?? 0))
        }
        fields += [
            .lines("problem", "Problem", detail: "What is failing, what you expected, what you checked"),
            .choice("environment", "Environment", options.environments.map(\.title)),
            .text("time", "When", detail: "optional, in your own words: last 30 minutes, 14:00 UTC"),
            .path("evidence", "Evidence", detail: "optional: files by path, commas between several"),
            .text("skills", "Skills", lastSkills, detail: options.skills.isEmpty
                  ? "optional: skill names, commas between several"
                  : "installed: " + options.skills.joined(separator: ", ")),
            .toggle("mcp", "MCP servers", true),
        ]
        var view = FormView(title: places == nil ? "Troubleshoot" : "Agent diagnosis",
                            subtitle: places == nil
                                ? "Give your agent a starting point. Follow the diagnosis in Chat."
                                : "Investigate a problem with evidence and project context.",
                            fields: fields, submitLabel: "start diagnosis")
        refresh(&view, options: options, isNew: places != nil)
        return view
    }

    // What the form says under its fields follows the environment and the MCP switch:
    // the servers the diagnosis reaches, and a warning for a live environment.
    static func refresh(_ form: inout FormView, options: RemoteDiagnosisOptions, isNew: Bool) {
        var extra: [String] = []
        if let environment = environment(form, options: options) {
            if let index = form.fields.firstIndex(where: { $0.id == "mcp" }) {
                let servers = options.servers(in: environment)
                form.fields[index].detail = !form.isOn("mcp") ? "off: project files and evidence only"
                    : servers.isEmpty ? "any servers the agent has set up"
                    : servers.joined(separator: ", ")
            }
            if environment.isDangerous {
                extra.append(" ⚠ \(environment.title) is live. The agent is told to keep every check read-only.")
            }
        }
        if !isNew {
            extra.append(" Projects: \(options.projects.joined(separator: ", ")) · Agent: \(options.agent.title)")
            extra.append(" The brief goes to Chat as your next message.")
        } else {
            extra.append(" The diagnosis starts as a new session and begins with read-only checks.")
        }
        form.extra = extra
    }

    static func environment(_ form: FormView, options: RemoteDiagnosisOptions) -> TroubleshootEnvironment? {
        let index = form.choice("environment")
        return options.environments.indices.contains(index) ? options.environments[index] : nil
    }

    @MainActor
    static func request(_ form: FormView, options: RemoteDiagnosisOptions, target: RemoteDiagnosis.Target,
                        places: [Place]? = nil) -> Result<RemoteDiagnosis, StationRefusal> {
        let evidence = list(form.text("evidence"))
        guard !form.text("problem").isBlank || !evidence.isEmpty else {
            return .failure(StationRefusal("Describe the problem or attach evidence to continue."))
        }
        guard let environment = environment(form, options: options) else {
            return .failure(StationRefusal("The site names no environment to diagnose in."))
        }
        var target = target
        var agent: AgentKind?
        if let places {
            let index = form.choice("place")
            guard places.indices.contains(index) else {
                return .failure(StationRefusal("Add a project to start the diagnosis."))
            }
            target = places[index].target
            agent = AgentKind.allCases[form.choice("agent")]
        }
        lastSkills = form.text("skills")
        return .success(RemoteDiagnosis(target: target, agent: agent, problem: form.text("problem"),
                                        environment: environment.name, incidentTime: form.text("time"),
                                        attachments: evidence, skills: list(form.text("skills")),
                                        mcpServersEnabled: form.isOn("mcp")))
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// The session's Troubleshoot tab: the form, filled in for the session it is on. What is
// typed outlives the tab going off screen, as the GUI keeps a half-written brief.
@MainActor
final class TroubleshootTab: SessionTabScreen {
    private let context: SessionTabContext
    private var options: RemoteDiagnosisOptions?
    private var form: FormView?
    private var failed: String?
    private static var drafts: [String: FormView] = [:]

    init(_ context: SessionTabContext) {
        self.context = context
        let id = context.sessionID, commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                let options = try await commands.diagnosisOptions(sessionID: id, agent: nil)
                guard let self else { return }
                self.options = options
                self.form = Self.drafts[id] ?? TroubleshootForm.form(options: options)
            } catch {
                self?.failed = error.message
            }
            self?.context.repaint()
        }
    }

    var place: KeyBindings.Place { .troubleshoot }

    // The form types into its fields, number keys included.
    var takesTyping: Bool { form != nil }

    func close() {
        if let form { Self.drafts[context.sessionID] = form }
    }

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        if let form { return form.frame(size: size, theme: context.theme) }
        let width = max(size.cols, 10)
        let text = failed ?? "Reading what a diagnosis can use…"
        let lines = ["", SidebarView.paint([(" " + text, failed == nil ? Style.dim : Style.code(.attention, theme: context.theme))], width: width)]
        let height = max(size.rows - 1, 0)
        return (Array(lines.prefix(height)) + Array(repeating: "", count: max(height - lines.count, 0))
                + [SidebarView.paint([(" esc chat", Style.dim)], width: width)], nil)
    }

    func handle(_ key: Key, rows: Int) -> SessionTabOutcome {
        guard var view = form, let options else {
            switch key {
            case .escape, .char("q", []): return .back
            default: return .ignored
            }
        }
        let outcome = view.handle(key)
        if outcome == .edited { TroubleshootForm.refresh(&view, options: options, isNew: false) }
        form = view
        switch outcome {
        case .cancel:
            return .back
        case .edited, .ignored:
            return outcome == .edited ? .handled : .ignored
        case .submit:
            start(view, options: options)
            return .handled
        }
    }

    private func start(_ view: FormView, options: RemoteDiagnosisOptions) {
        switch TroubleshootForm.request(view, options: options, target: .session(context.sessionID)) {
        case .failure(let refusal):
            form?.notice = refusal.message
        case .success(let request):
            form?.busy = true
            let commands = context.commands, id = context.sessionID
            _ = context.work { [weak self] in
                do throws(StationRefusal) {
                    _ = try await commands.startDiagnosis(request)
                    // What the form said is in the transcript now; a second brief is a
                    // new question about the same session.
                    Self.drafts[id] = nil
                    guard let self else { return }
                    self.form = TroubleshootForm.form(options: options)
                    self.form?.notice = "Diagnosis started: follow it in Chat (1)."
                } catch {
                    self?.form?.busy = false
                    self?.form?.notice = error.message
                }
                self?.context.repaint()
            }
        }
    }
}

// Tools → Troubleshoot: a diagnosis from scratch, in a project or workspace picked on the
// form, on the agent picked there. It opens as a new session, as the GUI's sheet does.
extension TUIApp {
    func newDiagnosis() {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let directory = try await commands.listDirectory()
                let options = try await commands.diagnosisOptions(sessionID: nil, agent: nil)
                let places: [TroubleshootForm.Place] = (directory.containers ?? []).compactMap { container in
                    switch container.kind {
                    case .project: TroubleshootForm.Place(name: container.name, target: .project(container.id))
                    case .workspace: TroubleshootForm.Place(name: container.name + " (workspace)", target: .workspace(container.id))
                    case .task: nil
                    }
                }
                guard let self else { return }
                guard !places.isEmpty else {
                    self.sidebar.notice = "Add a project to start a diagnosis."
                    return
                }
                let form = TroubleshootForm.form(options: options, places: places)
                self.taskForm = (form, { TroubleshootForm.refresh(&$0, options: options, isNew: true) }, { [weak self] form in
                    self?.startNewDiagnosis(form, options: options, places: places)
                })
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func startNewDiagnosis(_ form: FormView, options: RemoteDiagnosisOptions, places: [TroubleshootForm.Place]) {
        switch TroubleshootForm.request(form, options: options, target: places[0].target, places: places) {
        case .failure(let refusal):
            taskForm?.view.notice = refusal.message
        case .success(let request):
            taskForm?.view.busy = true
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    let id = try await commands.startDiagnosis(request)
                    guard let self else { return }
                    self.taskForm = nil
                    if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                    self.sidebar.clearFilter()
                    await self.open(id)
                } catch {
                    self?.taskForm?.view.busy = false
                    self?.taskForm?.view.notice = error.message
                }
                self?.paint()
            }
        }
    }
}
