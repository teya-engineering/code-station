import Foundation
import Testing
@testable import CodeStationCore

// The deployments come from the host's site file, so the runner is told which one a new
// troubleshoot brief starts on rather than reading the file itself.
@MainActor
struct ComposerEnvironmentTests {

    @Test func aNewBriefStartsOnTheEnvironmentTheHostNames() {
        let staging = TroubleshootEnvironment(name: "stg", title: "Staging")
        let runner = SessionRunner(paths: [:], defaultTroubleshootEnvironment: { staging })

        #expect(runner.composer.brief(UUID()).environment == staging)
    }

    @Test func withoutAHostChoiceABriefStartsOnProduction() {
        let runner = SessionRunner(paths: [:])

        let environment = runner.composer.brief(UUID()).environment

        #expect(environment.name == "production")
        #expect(environment.isDangerous)
    }
}
