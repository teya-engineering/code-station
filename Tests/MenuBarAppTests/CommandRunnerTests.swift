import Darwin
import Foundation
import Testing
@testable import MenuBarApp

struct CommandRunnerTests {
    private let scratch = ScratchDirectory(prefix: "command-runner")

    @Test func capturesBothStreamsAndExitStatus() async throws {
        let output = try await CommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf standard; printf problem >&2; exit 7"],
            timeout: .seconds(2)
        )

        #expect(output.output == "standard")
        #expect(output.errorOutput == "problem")
        #expect(output.status == 7)
        #expect(!output.succeeded)
    }

    @Test func drainsOutputPastTheCaptureLimit() async throws {
        let output = try await CommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes output | head -c 100000; yes error | head -c 100000 >&2"],
            timeout: .seconds(2),
            outputByteLimit: 1_024
        )

        #expect(output.status == 0)
        #expect(output.output.utf8.count == 1_024)
        #expect(output.errorOutput.utf8.count == 1_024)
        #expect(output.outputTruncated)
        #expect(output.errorOutputTruncated)
    }

    @Test func writesStandardInputAndClosesIt() async throws {
        let input = Data("from standard input".utf8)
        let output = try await CommandRunner.run(
            executable: "/bin/cat",
            input: input,
            timeout: .seconds(2)
        )

        #expect(output.succeeded)
        #expect(output.output == "from standard input")
    }

    @Test func runsInTheRequestedWorkingDirectory() async throws {
        let folder = scratch.path("workspace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let output = try await CommandRunner.run(
            executable: "/bin/pwd",
            currentDirectory: folder,
            timeout: .seconds(2)
        )

        #expect(output.succeeded)
        let reported = URL(fileURLWithPath: output.output.trimmed).resolvingSymlinksInPath().path
        let expected = folder.resolvingSymlinksInPath().path
        #expect(reported == expected)
    }

    @Test func timesOutACommandThatDoesNotExit() async {
        do {
            _ = try await CommandRunner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: .milliseconds(50)
            )
            Issue.record("expected the command to time out")
        } catch let error as CommandRunner.RunError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func cancellationStopsTheChild() async {
        let task = Task {
            try await CommandRunner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected the command to be cancelled")
        } catch let error as CommandRunner.RunError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // Every descriptor the app has open at the moment of the spawn is a candidate for
    // being inherited, and the ones that matter are the other agent turns' pipes: a child
    // holding one keeps it from ever reaching end of file, so the turn that owns it waits
    // on a stream nobody will close and hangs for good.
    @Test func doesNotHandUnrelatedDescriptorsToTheChild() async throws {
        let stray = Pipe()
        defer {
            try? stray.fileHandleForReading.close()
            try? stray.fileHandleForWriting.close()
        }
        // The rest of the suite is opening and closing descriptors the whole time, and a
        // child numbers what it opens for itself from the bottom of the range. Parking the
        // marker well clear of both leaves only one way for the child to be holding it.
        let marker = fcntl(stray.fileHandleForWriting.fileDescriptor, F_DUPFD, 64)
        try #require(marker >= 64)
        defer { Darwin.close(marker) }

        let output = try await CommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "ls /dev/fd"],
            timeout: .seconds(5)
        )

        let inherited = output.output.split(whereSeparator: \.isNewline).map(String.init)
        #expect(!inherited.contains("\(marker)"), "child holds \(inherited)")
    }

    @Test func timeoutKillsADescendantThatInheritedThePipes() async throws {
        let pidFile = scratch.path("child.pid")
        let started = ContinuousClock.now
        do {
            _ = try await CommandRunner.run(
                executable: "/bin/sh",
                arguments: backgroundChildArguments(pidFile: pidFile,
                                                     keepLeaderRunning: true),
                timeout: .milliseconds(200)
            )
            Issue.record("expected inherited pipes to time out")
        } catch let error as CommandRunner.RunError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(5))
        let pid = try #require(descendantPID(in: pidFile))
        #expect(!processExists(pid))
    }

    @Test func successfulCommandKillsADescendantBeforeReturning() async throws {
        let pidFile = scratch.path("child.pid")

        let output = try await CommandRunner.run(
            executable: "/bin/sh",
            arguments: backgroundChildArguments(pidFile: pidFile),
            timeout: .seconds(3)
        )

        #expect(output.succeeded)
        let pid = try #require(descendantPID(in: pidFile))
        #expect(!processExists(pid))
    }

    @Test func cancellationKillsADescendantThatInheritedThePipes() async throws {
        let pidFile = scratch.path("child.pid")
        let arguments = backgroundChildArguments(pidFile: pidFile,
                                                  keepLeaderRunning: true)
        let task = Task {
            try await CommandRunner.run(
                executable: "/bin/sh",
                arguments: arguments,
                timeout: .seconds(10)
            )
        }
        try #require(await waitUntil { descendantPID(in: pidFile) != nil })
        let pid = try #require(descendantPID(in: pidFile))
        let started = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected inherited pipes to be cancelled")
        } catch let error as CommandRunner.RunError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(!processExists(pid))
    }

    @Test func reportsLaunchFailuresAsTypedErrors() async {
        do {
            _ = try await CommandRunner.run(
                executable: "/not/a/real/executable",
                timeout: .seconds(1)
            )
            Issue.record("expected the command not to launch")
        } catch let error as CommandRunner.RunError {
            guard case .launch = error else {
                Issue.record("unexpected runner error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func reliablyRunsCommandsThatExitImmediately() async throws {
        for _ in 0..<100 {
            let output = try await CommandRunner.run(
                executable: "/usr/bin/true",
                timeout: .seconds(5)
            )
            #expect(output.succeeded)
        }
    }

    @Test func gitRunnerBoundsAndDrainsBothStreams() async {
        let tool = GitInspector.GitTool(path: "/bin/sh", searchPath: "/usr/bin:/bin")
        let output = await GitInspector.offMain {
            GitInspector.run(
                tool,
                ["-c", "yes output | head -c 100000; yes error | head -c 100000 >&2"],
                timeout: 2,
                captureByteLimit: 1_024
            )
        }

        #expect(output.status == 0)
        #expect(output.text.utf8.count == 1_024)
        #expect(output.errorText.utf8.count == 1_024)
        #expect(output.truncated)
    }

    @Test func gitRunnerTimeoutKillsADescendantThatInheritedThePipes() async throws {
        let pidFile = scratch.path("child.pid")
        let tool = GitInspector.GitTool(path: "/bin/sh", searchPath: "/usr/bin:/bin")
        let arguments = backgroundChildArguments(pidFile: pidFile,
                                                  keepLeaderRunning: true)
        let started = ContinuousClock.now
        let output = await GitInspector.offMain {
            GitInspector.run(tool, arguments, timeout: 0.2)
        }

        #expect(output.status == -1)
        #expect(output.failureMessage == "Command timed out.")
        #expect(started.duration(to: .now) < .seconds(5))
        let pid = try #require(descendantPID(in: pidFile))
        #expect(!processExists(pid))
    }

    @Test func gitWorkRunsSequentially() async {
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await GitInspector.offMain {
                        probe.enter()
                        usleep(10_000)
                        probe.leave()
                    }
                }
            }
        }

        #expect(probe.peak == 1)
    }

    @Test func codexUsageReaderCompletesItsBoundedExchange() async throws {
        let script = scratch.path("codex-usage")
        try FixtureCLI.write("""
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r usage
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
        """, to: script)

        let usage = await CodexUsageReader.read(at: script.path, searchPath: "/usr/bin:/bin")

        #expect(usage?.windows.map(\.usedPercent) == [12])
    }

    @Test func codexModelReaderCollectsEveryPage() async throws {
        let script = scratch.path("codex-models")
        try FixtureCLI.write("""
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r first
        printf '%s\\n' '{"id":2,"result":{"data":[{"id":"catalog-astra","model":"gpt-5.6-astra","displayName":"Astra","description":"Fast account model.","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"ultra"}],"isDefault":true}],"nextCursor":"page-2"}}'
        IFS= read -r second
        case "$second" in *'"cursor":"page-2"'*) ;; *) exit 9 ;; esac
        printf '%s\\n' '{"id":3,"result":{"data":[{"model":"gpt-5.6-terra","displayName":"Terra","supportedReasoningEfforts":["low","high"]},{"model":"internal","displayName":"Internal","hidden":true}],"nextCursor":null}}'
        """, to: script)

        let models = try #require(await CodexModelReader.read(
            at: script.path, searchPath: "/usr/bin:/bin"))

        #expect(models.compactMap(\.id) == ["gpt-5.6-astra", "gpt-5.6-terra"])
        #expect(models[0].title == "Astra")
        #expect(models[0].detail == "Fast account model.")
        #expect(models[0].supportedEfforts == ["low", "ultra"])
        #expect(models[0].isDefault)
        #expect(models[1].supportedEfforts == ["low", "high"])
    }

    @Test func codexModelReaderRejectsAnIncompleteExchange() async throws {
        let script = scratch.path("codex-model-error")
        try FixtureCLI.write("""
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r models
        printf '%s\\n' '{"id":2,"error":{"code":-32601,"message":"unsupported"}}'
        """, to: script)

        let models = await CodexModelReader.read(at: script.path,
                                                 searchPath: "/usr/bin:/bin")

        #expect(models == nil)
    }

    @MainActor
    @Test func aFailedModelRefreshKeepsTheLastCatalog() async throws {
        let script = scratch.path("codex-model-refresh-error")
        try FixtureCLI.write("""
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r models
        printf '%s\\n' '{"id":2,"error":{"code":-32601,"message":"unsupported"}}'
        """, to: script)
        let existing = [ModelChoice.Option(id: "gpt-5.6-astra", title: "Astra",
                                           detail: "Fast.")]
        let runner = SessionRunner(paths: [.codex: script.path], codexModels: existing)

        await runner.refreshCodexModels()

        #expect(runner.codexModels == existing)
    }

    private func backgroundChildArguments(pidFile: URL,
                                          keepLeaderRunning: Bool = false) -> [String] {
        let finish = keepLeaderRunning ? "sleep 30" : "exit 0"
        return ["-c", "sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; \(finish)",
         "command-runner-test", pidFile.path]
    }

    private func descendantPID(in file: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processExists(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private final class ConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0

        func enter() {
            lock.withLock {
                active += 1
                peak = max(peak, active)
            }
        }

        func leave() {
            lock.withLock { active -= 1 }
        }
    }
}
