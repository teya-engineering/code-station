import Foundation
import Testing
@testable import MenuBarApp

// The order the CLI calls go out in is what decides whether a changed server ends up
// registered once, twice, or not at all. All three agents share this plan, so the rule is
// checked here once rather than through any one of their CLIs.
struct CLIRegistrarPlanTests {
    private func server(_ name: String) -> Server {
        Server(name: name, command: "/usr/bin/true", args: [], url: nil, type: nil,
               env: [], headers: [], disabled: false)
    }

    private func add(_ server: Server) -> [String]? { ["mcp", "add", server.name] }
    private func remove(_ name: String) -> [String] { ["mcp", "remove", name] }

    @Test func aServerTheCLIDoesNotHaveIsOnlyAdded() {
        let plan = CLIRegistrar.plan([server("grafana")],
                                     add: add, remove: remove,
                                     isRegistered: { _ in false })

        #expect(plan.steps == [["mcp", "add", "grafana"]])
        #expect(plan.names == ["grafana"])
    }

    // None of the CLIs can edit a registration, so a changed token or command only lands
    // if the old entry is taken out first - and in that order, or the add is undone.
    @Test func aServerTheCLIAlreadyHasIsRemovedBeforeItIsAddedAgain() {
        let plan = CLIRegistrar.plan([server("grafana")],
                                     add: add, remove: remove,
                                     isRegistered: { _ in true })

        #expect(plan.steps == [["mcp", "remove", "grafana"], ["mcp", "add", "grafana"]])
        #expect(plan.names == ["grafana"])
    }

    // A server the CLI cannot take - a transport it does not speak, or a command that
    // could not be resolved - has no step to run. Naming it anyway would mark it busy for
    // a step that never comes, and it would sit spinning until the app restarted.
    @Test func aServerWithNoArgumentsIsLeftOutOfTheStepsAndTheNames() {
        let plan = CLIRegistrar.plan([server("unsupported")],
                                     add: { _ in nil }, remove: remove,
                                     isRegistered: { _ in true })

        #expect(plan.steps.isEmpty)
        #expect(plan.names.isEmpty)
    }

    // One server the CLI cannot take must not stop the ones beside it from registering.
    @Test func theOthersStillRegisterAroundOneItCannotTake() {
        let servers = [server("first"), server("skipped"), server("third")]
        let plan = CLIRegistrar.plan(servers,
                                     add: { $0.name == "skipped" ? nil : self.add($0) },
                                     remove: remove,
                                     isRegistered: { $0 == "third" })

        #expect(plan.steps == [["mcp", "add", "first"],
                               ["mcp", "remove", "third"],
                               ["mcp", "add", "third"]])
        #expect(plan.names == ["first", "third"])
    }

    // Names are what get marked busy and what a failure is reported against, so every
    // named server must be one the steps actually cover.
    @Test func everyNamedServerHasAnAddStepOfItsOwn() {
        let servers = [server("a"), server("b"), server("c")]
        let plan = CLIRegistrar.plan(servers,
                                     add: { $0.name == "b" ? nil : self.add($0) },
                                     remove: remove,
                                     isRegistered: { $0 == "a" })

        for name in plan.names {
            #expect(plan.steps.contains(["mcp", "add", name]))
        }
        #expect(plan.steps.count == plan.names.count + 1)
    }

    @Test func nothingToSyncPlansNothing() {
        let plan = CLIRegistrar.plan([], add: add, remove: remove, isRegistered: { _ in true })

        #expect(plan.steps.isEmpty)
        #expect(plan.names.isEmpty)
    }
}
