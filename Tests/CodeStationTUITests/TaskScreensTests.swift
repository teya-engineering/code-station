@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // Tasks in the TUI, as the GUI's New task sheet, task screen, run sheet and scheduled
    // run dialog have them: a task made from Add, its prompt and inputs edited, a run
    // with its inputs filled in (a file input as a typed path), its run history, its
    // schedule, and a scheduled run waiting for confirmation answered.
    @MainActor
    @Suite
    struct TaskScreensTests {

        // Opens the actions menu of the sidebar row whose text holds `row`.
        private func openMenu(_ tui: TUIHarness, on row: String) async throws {
            await tui.press(.char("g", []))
            for _ in 0..<20 where tui.sidebarLine(containing: row)?.text.hasPrefix("▸") != true {
                await tui.press(.down([]))
            }
            try #require(tui.sidebarLine(containing: row)?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("a", []))
        }

        // Points the open menu at `entry` and chooses it.
        private func choose(_ tui: TUIHarness, _ entry: String) async throws {
            let target = try #require(tui.frame.firstIndex { $0.text.contains(entry) }, "\(tui.text)")
            let current = try #require(tui.frame.firstIndex { $0.text.hasPrefix("  ▸ ") }, "\(tui.text)")
            for _ in 0..<abs(target - current) { await tui.press(target > current ? .down([]) : .up([])) }
            await tui.press(.enter([]))
        }

        // Moves the open form's pointer to the field labelled `label`.
        private func field(_ tui: TUIHarness, _ label: String) async throws {
            let focused = { tui.frame.contains { $0.text.hasPrefix("  ▸ \(label) ") } }
            for _ in 0..<12 where !focused() { await tui.press(.down([])) }
            try #require(focused(), "\(tui.text)")
        }

        // Opens the task's screen from the sidebar.
        private func openTask(_ tui: TUIHarness, _ name: String) async throws {
            await tui.press(.char("g", []))
            for _ in 0..<20 where tui.sidebarLine(containing: name)?.text.hasPrefix("▸") != true {
                await tui.press(.down([]))
            }
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.contains(" PROMPT") }, "\(tui.text)")
        }

        private func task(_ tui: TUIHarness, prompt: String, inputs: [TaskInput] = [],
                          schedule: TaskSchedule? = nil) throws -> Project {
            let task = try tui.addTask("Review")
            var spec = try #require(task.task)
            spec.prompt = prompt
            spec.inputs = inputs
            spec.schedule = schedule
            tui.store.setTaskSpec(spec, for: task.id)
            return task
        }

        // Add's New task opens the form: a name is asked for first, the prompt's holes
        // are named as it is typed, and Enter makes the task and shows its screen.
        @Test func aTaskIsMadeFromAdd() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            try await tui.start()

            await tui.press(.char("G", []))
            for _ in 0..<6 where tui.sidebarLine(containing: "Add")?.text.hasPrefix("▸") != true {
                await tui.press(.up([]))
            }
            await tui.press(.enter([]))
            try await choose(tui, "New task…")
            #expect(tui.frame[0].text == " New task", "\(tui.text)")
            for label in ["Name", "Prompt", "Agent", "When", "Run it now"] {
                #expect(tui.contains(label), "\(label)\n\(tui.text)")
            }
            #expect(!tui.contains("Repeat"), "\(tui.text)")

            await tui.press(.enter([]))
            #expect(tui.frame.last?.text.contains("Enter a name for the task.") == true, "\(tui.text)")

            await tui.type("Review")
            await tui.press(.down([]))
            await tui.type("Review PR {{pr}}")
            #expect(tui.contains("Asks for pr on each run."), "\(tui.text)")
            try await field(tui, "When")
            await tui.press(.right([]))
            #expect(tui.contains("Repeat"), "\(tui.text)")
            await tui.press(.left([]))

            await tui.press(.enter([]))

            #expect(await waitUntil { tui.store.projects.contains { $0.kind == .adHoc } }, "\(tui.text)")
            let made = try #require(tui.store.projects.first { $0.kind == .adHoc })
            #expect(made.name == "Review")
            #expect(made.task?.prompt == "Review PR {{pr}}")
            #expect(made.task?.schedule == nil)
            #expect(await waitUntil { tui.topBar.first?.text.hasPrefix(" □ Review") == true }, "\(tui.text)")
            #expect(await waitUntil { tui.contains("{{pr}}") }, "\(tui.text)")
            #expect(tui.contains("Review PR {{pr}}"), "\(tui.text)")
        }

        // e edits the prompt, whose new hole shows as an input; i opens the input's form,
        // where a kind of Choice asks for its options, and saving dresses the input.
        @Test func thePromptAndAnInputAreEdited() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let made = try task(tui, prompt: "Deploy")
            try await tui.start()
            try await openTask(tui, "Review")

            await tui.press(.char("e", []))
            #expect(tui.frame[0].text == " Edit Review", "\(tui.text)")
            await tui.type(" to {{env}}")
            #expect(tui.contains("Each run asks for env before it starts."), "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.store.project(made.id)?.task?.prompt == "Deploy to {{env}}" }, "\(tui.text)")
            #expect(await waitUntil { tui.contains("{{env}}") }, "\(tui.text)")

            await tui.press(.char("i", []))
            #expect(tui.frame[0].text == " {{env}}", "\(tui.text)")
            #expect(!tui.contains("Options"), "\(tui.text)")
            try await field(tui, "Kind")
            await tui.press(.right([]), .right([]))
            #expect(tui.line(containing: "Kind")?.text.contains("‹ Choice ›") == true, "\(tui.text)")
            try await field(tui, "Options")
            await tui.type("dev, prod")
            await tui.press(.enter([]))

            #expect(await waitUntil { tui.store.project(made.id)?.task?.inputs.first?.kind == .choice }, "\(tui.text)")
            #expect(tui.store.project(made.id)?.task?.inputs.first?.options == ["dev", "prod"])
            #expect(await waitUntil { tui.mainLine(containing: "{{env}}  Env")?.text.contains("choice") == true }, "\(tui.text)")
        }

        // n on a task whose prompt asks for something opens the run form: a field per
        // input, a file input completed with Tab, and the prompt it will send. Enter
        // starts the run, which opens with the prompt sent.
        @Test func aRunAsksForItsInputsAndOpens() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30), agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
            """)
            defer { tui.tearDown() }
            let notes = tui.scratch.path("release-notes.md")
            try "notes\n".write(to: notes, atomically: true, encoding: .utf8)
            let made = try task(tui, prompt: "Review PR {{pr}} using {{file}}",
                                inputs: [TaskInput(name: "file", kind: .path)])
            try await tui.start()
            try await openTask(tui, "Review")

            await tui.press(.char("n", []))
            #expect(tui.frame[0].text == " Run Review", "\(tui.text)")
            #expect(tui.contains("THE PROMPT"), "\(tui.text)")
            await tui.press(.enter([]))
            #expect(tui.frame.last?.text.contains("Fill in Pr first.") == true, "\(tui.text)")
            await tui.type("12")
            #expect(tui.contains("Review PR 12 using"), "\(tui.text)")
            try await field(tui, "File")
            await tui.type(tui.scratch.path("release").path)
            await tui.press(.tab([]))
            #expect(tui.contains("release-notes.md"), "\(tui.text)")

            await tui.press(.enter([]))

            let sent = "Review PR 12 using \(notes.path)"
            #expect(await waitUntil {
                tui.store.standaloneSessions(for: made.id).first?.messages.first?.text == sent
            }, "\(tui.text)")
            #expect(await waitUntil { tui.topBar.first?.text.contains("Review /") == true }, "\(tui.text)")
            #expect(tui.store.project(made.id)?.task?.lastValues["pr"] == "12")
        }

        // The runs are listed under their day, saying who started each and what it was
        // given; f filters them to the scheduled ones.
        @Test func theRunHistoryIsListedAndFiltered() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 110, rows: 30))
            defer { tui.tearDown() }
            let made = try task(tui, prompt: "Sweep {{area}}")
            let byHand = try tui.store.insertSession(in: made.id, seed: .init(agent: .claudeCode)).get()
            tui.store.renameSession(byHand.id, to: "Docs sweep")
            tui.store.setTaskValues(["area": "docs"], for: byHand.id)
            let scheduled = try tui.store.insertSession(in: made.id, seed: .init(agent: .claudeCode)).get()
            tui.store.renameSession(scheduled.id, to: "Tests sweep")
            tui.store.markScheduledRun(scheduled.id)
            tui.store.setTaskValues(["area": "tests"], for: scheduled.id)
            try await tui.start()
            try await openTask(tui, "Review")

            #expect(await waitUntil { tui.contains("Docs sweep") }, "\(tui.text)")
            #expect(tui.contains("RUNS 2"), "\(tui.text)")
            #expect(tui.contains("Today"), "\(tui.text)")
            #expect(tui.mainLine(containing: "Docs sweep")?.text.contains("Run by you · area docs") == true, "\(tui.text)")
            #expect(tui.mainLine(containing: "Tests sweep")?.text.contains("Scheduled · area tests") == true, "\(tui.text)")

            await tui.press(.char("f", []))
            #expect(tui.contains("[Scheduled]"), "\(tui.text)")
            #expect(tui.mainText.contains("Tests sweep"), "\(tui.text)")
            #expect(!tui.mainText.contains("Docs sweep"), "\(tui.text)")
        }

        // s opens the schedule form; every few minutes asks for the interval, the run
        // limit and whether to ask first. Saving turns the schedule on, which the screen
        // and the sidebar's clock show.
        @Test func aScheduleIsSet() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 110, rows: 30))
            defer { tui.tearDown() }
            let made = try task(tui, prompt: "Check the build")
            try await tui.start()
            try await openTask(tui, "Review")

            await tui.press(.char("s", []))
            #expect(tui.frame[0].text == " Schedule Review", "\(tui.text)")
            #expect(tui.contains("Repeat"), "\(tui.text)")
            #expect(!tui.contains("Stop after"), "\(tui.text)")
            await tui.press(.right([]))
            #expect(tui.contains("Stop after"), "\(tui.text)")
            try await field(tui, "Every")
            await tui.press(.char("u", .ctrl))
            await tui.type("15")
            try await field(tui, "Stop after")
            await tui.type("3")
            try await field(tui, "Ask before each run")
            await tui.press(.char(" ", []))
            #expect(tui.contains("Every 15 minutes."), "\(tui.text)")

            await tui.press(.enter([]))

            #expect(await waitUntil { tui.store.project(made.id)?.task?.schedule?.isActive == true }, "\(tui.text)")
            let saved = try #require(tui.store.project(made.id)?.task?.schedule)
            #expect(saved.interval == 15 && saved.maximumRuns == 3 && saved.requiresConfirmation)
            #expect(await waitUntil { tui.contains("Every 15 minutes · Next run in") }, "\(tui.text)")
            #expect(tui.contains("0 of 3 runs done · asks first"), "\(tui.text)")
            #expect(await waitUntil { tui.sidebarLine(containing: "Review")?.text.contains("◷") == true },
                    "\(tui.sidebarText)")
        }

        // A run waiting for confirmation shows in the sidebar and on the screen. c asks
        // as the GUI's dialog does; Skip lets it pass and the task stops waiting. The
        // task's menu offers the same question.
        @Test func aWaitingRunIsConfirmed() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 110, rows: 30))
            defer { tui.tearDown() }
            var rule = TaskSchedule()
            rule.isEnabled = true
            rule.interval = 15
            rule.requiresConfirmation = true
            rule.restart()
            rule.waitForConfirmation()
            let made = try task(tui, prompt: "Check the build", schedule: rule)
            try await tui.start()

            #expect(tui.sidebarLine(containing: "Review")?.text.contains("◷ confirm") == true, "\(tui.sidebarText)")
            try await openMenu(tui, on: "Review")
            #expect(tui.line(containing: "Confirm scheduled run…")?.text.hasPrefix("  ▸ ") == true, "\(tui.text)")
            await tui.press(.escape)

            try await openTask(tui, "Review")
            #expect(await waitUntil { tui.contains("Waiting for you to confirm the next run") }, "\(tui.text)")
            await tui.press(.char("c", []))
            #expect(tui.frame[0].text == " Run \"Review\"?", "\(tui.text)")
            #expect(tui.contains("Its every 15 minutes timer is due."), "\(tui.text)")
            #expect(tui.contains("[ Run now ]  [ Skip this run ]  [ Turn off timer ]"), "\(tui.text)")

            await tui.press(.escape)
            #expect(tui.store.project(made.id)?.task?.schedule?.isWaitingForConfirmation == true)

            await tui.press(.char("c", []), .tab([]), .enter([]))
            #expect(await waitUntil { tui.store.project(made.id)?.task?.schedule?.isWaitingForConfirmation == false },
                    "\(tui.text)")
            #expect(tui.store.project(made.id)?.task?.schedule?.isActive == true)
            #expect(tui.store.standaloneSessions(for: made.id).isEmpty)
            #expect(await waitUntil { tui.sidebarLine(containing: "Review")?.text.contains("confirm") == false },
                    "\(tui.sidebarText)")
        }
    }
}
