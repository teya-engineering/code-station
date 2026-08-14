import Foundation
import Testing
@testable import MenuBarApp

struct TaskTemplateTests {
    @Test func findsEveryHoleInTheOrderThePromptReadsThem() {
        let found = TaskTemplate.placeholders(in: "Review {{pr}} on {{repo}}, then tell {{pr}}.")

        #expect(found == ["pr", "repo"])
    }

    @Test func treatsSpellingsThatDifferOnlyInCaseOrSpacingAsOneHole() {
        let found = TaskTemplate.placeholders(in: "{{PR}} and {{  pr  }} and {{pr}}")

        #expect(found == ["PR"])
    }

    @Test func ignoresBracesThatDoNotHoldAName() {
        let found = TaskTemplate.placeholders(in: "{{}} {{ }} {{a.b}} {{unclosed and {{ok}}")

        #expect(found == ["ok"])
    }

    @Test func fillsEveryHoleWithWhatTheRunWasGiven() {
        let spec = TaskSpec(prompt: "Review {{pr}} on {{repo}}.\nSay {{pr}} twice.")

        let prompt = TaskTemplate.render(spec, values: ["pr": "431", "repo": "api"])

        #expect(prompt == "Review 431 on api.\nSay 431 twice.")
    }

    @Test func leavesOutALineThatOnlyAskedForSomethingLeftBlank() {
        let spec = TaskSpec(prompt: "Review {{pr}}.\nFocus on {{focus}}.\nPost the findings.",
                            inputs: [TaskInput(name: "focus", required: false)])

        let prompt = TaskTemplate.render(spec, values: ["pr": "431", "focus": ""])

        #expect(prompt == "Review 431.\nPost the findings.")
    }

    @Test func keepsALineWhereSomethingElseOnItWasFilledIn() {
        let spec = TaskSpec(prompt: "Review {{pr}} about {{topic}}.")

        let prompt = TaskTemplate.render(spec, values: ["pr": "431", "topic": ""])

        #expect(prompt == "Review 431 about .")
    }

    @Test func aTogglePutsItsOwnWordsInThePromptOrTakesItsLineAway() {
        let spec = TaskSpec(prompt: "Ship it.\n{{tests}}",
                            inputs: [TaskInput(name: "tests", kind: .toggle,
                                               options: ["Run the full test suite first.", ""])])

        #expect(TaskTemplate.render(spec, values: ["tests": "on"])
            == "Ship it.\nRun the full test suite first.")
        #expect(TaskTemplate.render(spec, values: ["tests": "off"]) == "Ship it.")
    }

    @Test func aPromptWithoutHolesIsSentExactlyAsItWasWritten() {
        let spec = TaskSpec(prompt: "  Draft the release notes.  ")

        #expect(TaskTemplate.render(spec, values: [:]) == "  Draft the release notes.  ")
    }

    @Test func dressesEachHoleWithWhatWasSavedForItAndKeepsThePromptsSpelling() {
        let spec = TaskSpec(prompt: "Deploy {{Service}} to {{env}}.",
                            inputs: [TaskInput(name: "service", label: "Which service"),
                                     TaskInput(name: "gone", hint: "no longer asked for")])

        let inputs = TaskTemplate.inputs(in: spec)

        #expect(inputs.map(\.name) == ["Service", "env"])
        #expect(inputs[0].title == "Which service")
        #expect(inputs[1].title == "Env")
        #expect(inputs[1].kind == .text)
        #expect(inputs[1].required)
    }

    @Test func savingAnInputReplacesTheOneForThatHoleAndLeavesTheRestAlone() {
        let spec = TaskSpec(prompt: "{{env}}",
                            inputs: [TaskInput(name: "env"), TaskInput(name: "old")])

        let saved = TaskTemplate.saving(TaskInput(name: "ENV", kind: .choice,
                                                  options: ["dev", "prod"]), in: spec)

        #expect(saved.count == 2)
        #expect(saved[0].kind == .choice)
        #expect(saved[1].name == "old")
    }

    @Test func summarisesWhatARunWasGivenAndSkipsWhatItWasNot() {
        let inputs = [TaskInput(name: "pr"),
                      TaskInput(name: "focus", required: false),
                      TaskInput(name: "deep", kind: .toggle)]

        let summary = TaskTemplate.summary(of: ["pr": "431", "focus": "", "deep": "on"],
                                           inputs: inputs)

        #expect(summary == "pr 431 · deep on")
    }

    @Test func cutsALongValueDownToTheWidthOfARunRow() {
        let summary = TaskTemplate.summary(of: ["note": String(repeating: "a", count: 40)],
                                           inputs: [TaskInput(name: "note")])

        #expect(summary == "note " + String(repeating: "a", count: 28) + "…")
    }
}

@MainActor
struct TaskRunPromptTests {
    @Test func asksForNothingWhenThePromptHasNoHoles() {
        let plain = Project(name: "Notes", path: "/tmp/notes", kind: .adHoc,
                            task: TaskSpec(prompt: "Draft the release notes."))
        let asking = Project(name: "Review", path: "/tmp/review", kind: .adHoc,
                             task: TaskSpec(prompt: "Review {{pr}}."))

        #expect(!TaskRun.needsInput(plain))
        #expect(TaskRun.needsInput(asking))
        #expect(!TaskRun.needsInput(Project(name: "Plain", path: "/tmp/plain")))
    }

    @Test func addsTheRunsOwnNoteAfterEverythingTheTaskAlwaysSays() {
        let spec = TaskSpec(prompt: "Review {{pr}}.")

        let prompt = TaskRun.prompt(for: spec, values: ["pr": "431"],
                                    note: "  Skip the tests this time.  ")

        #expect(prompt == "Review 431.\n\nSkip the tests this time.")
    }

    @Test func sendsOnlyTheNoteWhenTheTemplateFilledInToNothing() {
        let spec = TaskSpec(prompt: "{{topic}}",
                            inputs: [TaskInput(name: "topic", required: false)])

        #expect(TaskRun.prompt(for: spec, values: ["topic": ""], note: "Just this.")
            == "Just this.")
        #expect(TaskRun.prompt(for: spec, values: ["topic": ""], note: "") == "")
    }
}

struct TaskSpecDecodingTests {
    @Test func readsATaskSavedBeforeItsPromptCouldAskForAnything() throws {
        let data = try JSONSerialization.data(withJSONObject: ["prompt": "Draft the notes."])

        let spec = try JSONDecoder().decode(TaskSpec.self, from: data)

        #expect(spec.prompt == "Draft the notes.")
        #expect(spec.inputs.isEmpty)
        #expect(spec.lastValues.isEmpty)
    }

    @Test func carriesItsInputsAndLastValuesThroughASaveAndALoad() throws {
        let spec = TaskSpec(prompt: "Deploy {{env}}.",
                            inputs: [TaskInput(name: "env", kind: .choice,
                                               options: ["dev", "prod"], required: false)],
                            lastValues: ["env": "prod"])

        let decoded = try JSONDecoder().decode(TaskSpec.self,
                                               from: JSONEncoder().encode(spec))

        #expect(decoded == spec)
    }

    @Test func readsAnInputSavedWithOnlyItsName() throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": "pr"])

        let input = try JSONDecoder().decode(TaskInput.self, from: data)

        #expect(input == TaskInput(name: "pr"))
    }
}
