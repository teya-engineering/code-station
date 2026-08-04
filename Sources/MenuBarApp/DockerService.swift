import Foundation
import Observation

// One running container, as `docker ps` reports it.
struct DockerContainer: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: String

    // One line of `docker ps --format {{json .}}`.
    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["ID"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (object["Names"] as? String) ?? id
        image = (object["Image"] as? String) ?? ""
        status = (object["Status"] as? String) ?? ""
        ports = (object["Ports"] as? String) ?? ""
    }

    // Only the published ports are worth showing, and only the host side of them:
    // "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp" says 5432 twice.
    var publishedPorts: String {
        let ports = ports
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { mapping -> String? in
                guard let arrow = mapping.range(of: "->") else { return nil }
                let host = mapping[..<arrow.lowerBound]
                return host.split(separator: ":").last.map(String.init)
            }
        var seen: Set<String> = []
        return ports.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

@MainActor
@Observable
final class DockerService {
    private(set) var containers: [DockerContainer] = []
    private(set) var stopping: Set<String> = []
    private(set) var failure: String?
    // Nothing has been asked of docker yet, so an empty list means "not looked" rather
    // than "nothing running".
    private(set) var hasLoaded = false

    var isAvailable: Bool { ProcessManager.resolve("docker") != nil }

    func refresh() async {
        guard isAvailable else {
            containers = []
            failure = "Docker was not found. Install Docker Desktop, or start it if it is already installed."
            hasLoaded = true
            return
        }
        let result = await Self.run(["ps", "--no-trunc", "--format", "{{json .}}"])
        hasLoaded = true
        guard result.ok else {
            containers = []
            failure = result.failureMessage
            return
        }
        failure = nil
        containers = result.text
            .split(separator: "\n")
            .compactMap { DockerContainer(line: String($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Docker asks the container to quit and only kills it if it will not, so this can
    // sit for a few seconds on a container that ignores the signal.
    func stop(_ container: DockerContainer) async {
        stopping.insert(container.id)
        let result = await Self.run(["stop", container.id])
        stopping.remove(container.id)
        if !result.ok {
            failure = result.failureMessage
            return
        }
        await refresh()
    }

    // MARK: - Running docker

    private struct Output {
        var text = ""
        var errorText = ""
        var status: Int32 = -1

        var ok: Bool { status == 0 }
        var failureMessage: String {
            let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "docker exited with code \(status)." : trimmed
        }
    }

    private static func run(_ arguments: [String]) async -> Output {
        guard let path = ProcessManager.resolve("docker") else {
            return Output(errorText: "Docker was not found on PATH.")
        }
        let searchPath = ProcessManager.searchPath
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment

            let out = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = out
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice

            var result = Output()
            do {
                try process.run()
            } catch {
                result.errorText = error.localizedDescription
                return result
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            result.text = String(decoding: outData, as: UTF8.self)
            result.errorText = String(decoding: errorData, as: UTF8.self)
            result.status = process.terminationStatus
            return result
        }.value
    }
}
