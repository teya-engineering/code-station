import Foundation
import Observation

struct DockerContainer: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let image: String
    let command: String
    let status: String
    let ports: String
    let size: String
    let networks: String
    let mounts: String
    let composeProject: String?
    let composeService: String?

    init?(line: String) {
        guard let fields = dockerFields(from: line),
              let id = fields["ID"], !id.isEmpty else { return nil }
        self.id = id
        name = fields["Names"] ?? id
        image = fields["Image"] ?? ""
        command = fields["Command"] ?? ""
        status = fields["Status"] ?? ""
        ports = fields["Ports"] ?? ""
        size = fields["Size"] ?? ""
        networks = fields["Networks"] ?? ""
        mounts = fields["Mounts"] ?? ""
        let labels = fields["Labels"] ?? ""
        composeProject = dockerLabel("com.docker.compose.project", in: labels)
        composeService = dockerLabel("com.docker.compose.service", in: labels)
    }

    var shortID: String { String(id.prefix(12)) }

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

struct DockerImage: Identifiable, Sendable, Equatable {
    let imageID: String
    let repository: String
    let tag: String
    let digest: String
    let createdSince: String
    let size: String
    let containers: String

    var id: String { "\(imageID)|\(repository)|\(tag)" }

    init?(line: String) {
        guard let fields = dockerFields(from: line),
              let imageID = fields["ID"], !imageID.isEmpty else { return nil }
        self.imageID = imageID
        repository = fields["Repository"] ?? "<none>"
        tag = fields["Tag"] ?? "<none>"
        digest = fields["Digest"] ?? ""
        createdSince = fields["CreatedSince"] ?? ""
        size = fields["Size"] ?? ""
        containers = fields["Containers"] ?? ""
    }

    var reference: String {
        if repository == "<none>" { return "Untagged image" }
        if tag.isEmpty || tag == "<none>" { return repository }
        return "\(repository):\(tag)"
    }

    var shortID: String {
        let value = imageID.hasPrefix("sha256:") ? String(imageID.dropFirst(7)) : imageID
        return String(value.prefix(12))
    }
}

struct DockerNetwork: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let driver: String
    let scope: String
    let createdAt: String
    let isInternal: Bool
    let supportsIPv6: Bool
    let composeProject: String?

    init?(line: String) {
        guard let fields = dockerFields(from: line),
              let id = fields["ID"], !id.isEmpty else { return nil }
        self.id = id
        name = fields["Name"] ?? id
        driver = fields["Driver"] ?? ""
        scope = fields["Scope"] ?? ""
        createdAt = fields["CreatedAt"] ?? ""
        isInternal = fields["Internal"] == "true"
        supportsIPv6 = fields["IPv6"] == "true"
        composeProject = dockerLabel("com.docker.compose.project", in: fields["Labels"] ?? "")
    }

    var shortID: String { String(id.prefix(12)) }
    var created: String { String(createdAt.prefix(19)) }
}

struct DockerVolume: Identifiable, Sendable, Equatable {
    let id: String
    let driver: String
    let scope: String
    let mountpoint: String
    let size: String
    let composeProject: String?
    let composeVolume: String?

    init?(line: String) {
        guard let fields = dockerFields(from: line),
              let name = fields["Name"], !name.isEmpty else { return nil }
        id = name
        driver = fields["Driver"] ?? ""
        scope = fields["Scope"] ?? ""
        mountpoint = fields["Mountpoint"] ?? ""
        size = fields["Size"] ?? ""
        let labels = fields["Labels"] ?? ""
        composeProject = dockerLabel("com.docker.compose.project", in: labels)
        composeVolume = dockerLabel("com.docker.compose.volume", in: labels)
    }
}

@MainActor
@Observable
final class DockerService {
    private(set) var containers: [DockerContainer] = []
    private(set) var images: [DockerImage] = []
    private(set) var networks: [DockerNetwork] = []
    private(set) var volumes: [DockerVolume] = []
    private(set) var stopping: Set<String> = []

    private(set) var containerFailure: String?
    private(set) var imageFailure: String?
    private(set) var networkFailure: String?
    private(set) var volumeFailure: String?

    private(set) var hasLoadedContainers = false
    private(set) var hasLoadedImages = false
    private(set) var hasLoadedNetworks = false
    private(set) var hasLoadedVolumes = false

    var failure: String? { containerFailure }
    var hasLoaded: Bool { hasLoadedContainers }
    var isAvailable: Bool { ProcessManager.resolve("docker") != nil }

    func refresh() async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }

        async let containerResult = Self.run(["ps", "--no-trunc", "--size", "--format", "{{json .}}"])
        async let imageResult = Self.run(["image", "ls", "--no-trunc", "--format", "{{json .}}"])
        async let networkResult = Self.run(["network", "ls", "--no-trunc", "--format", "{{json .}}"])
        async let volumeResult = Self.run(["volume", "ls", "--format", "{{json .}}"])

        let results = await (containerResult, imageResult, networkResult, volumeResult)
        applyContainers(results.0)
        applyImages(results.1)
        applyNetworks(results.2)
        applyVolumes(results.3)
    }

    func refreshContainers() async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }
        applyContainers(await Self.run(["ps", "--no-trunc", "--size", "--format", "{{json .}}"]))
    }

    // Docker asks the container to quit and only kills it if it will not, so this can
    // sit for a few seconds on a container that ignores the signal.
    func stop(_ container: DockerContainer) async {
        stopping.insert(container.id)
        let result = await Self.run(["stop", container.id])
        stopping.remove(container.id)
        if !result.ok {
            containerFailure = result.failureMessage
            return
        }
        containers.removeAll { $0.id == container.id }
        await refreshContainers()
    }

    private func applyContainers(_ result: Output) {
        hasLoadedContainers = true
        guard result.ok else {
            containers = []
            containerFailure = result.failureMessage
            return
        }
        containerFailure = nil
        containers = result.text
            .split(separator: "\n")
            .compactMap { DockerContainer(line: String($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func applyImages(_ result: Output) {
        hasLoadedImages = true
        guard result.ok else {
            images = []
            imageFailure = result.failureMessage
            return
        }
        imageFailure = nil
        images = result.text
            .split(separator: "\n")
            .compactMap { DockerImage(line: String($0)) }
            .sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
    }

    private func applyNetworks(_ result: Output) {
        hasLoadedNetworks = true
        guard result.ok else {
            networks = []
            networkFailure = result.failureMessage
            return
        }
        networkFailure = nil
        networks = result.text
            .split(separator: "\n")
            .compactMap { DockerNetwork(line: String($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func applyVolumes(_ result: Output) {
        hasLoadedVolumes = true
        guard result.ok else {
            volumes = []
            volumeFailure = result.failureMessage
            return
        }
        volumeFailure = nil
        volumes = result.text
            .split(separator: "\n")
            .compactMap { DockerVolume(line: String($0)) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func dockerUnavailable() {
        let message = "Docker was not found. Install Docker Desktop, or start it if it is already installed."
        containers = []
        images = []
        networks = []
        volumes = []
        containerFailure = message
        imageFailure = message
        networkFailure = message
        volumeFailure = message
        hasLoadedContainers = true
        hasLoadedImages = true
        hasLoadedNetworks = true
        hasLoadedVolumes = true
    }

    // MARK: - Running docker

    private struct Output: Sendable {
        var text = ""
        var errorText = ""
        var status: Int32 = -1

        var ok: Bool { status == 0 }
        var failureMessage: String {
            let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "docker exited with code \(status)." : trimmed
        }
    }

    nonisolated private static func run(_ arguments: [String]) async -> Output {
        guard let path = ProcessManager.resolve("docker") else {
            return Output(errorText: "Docker was not found on PATH.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath

        do {
            let output = try await CommandRunner.run(
                executable: path,
                arguments: arguments,
                environment: environment,
                timeout: .seconds(30)
            )
            return Output(text: output.output,
                          errorText: output.errorOutput,
                          status: output.status)
        } catch {
            return Output(errorText: error.localizedDescription)
        }
    }
}

private func dockerFields(from line: String) -> [String: String]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object.reduce(into: [:]) { fields, entry in
        if let value = entry.value as? String {
            fields[entry.key] = value
        }
    }
}

private func dockerLabel(_ name: String, in labels: String) -> String? {
    let prefix = "\(name)="
    guard let label = labels.split(separator: ",").first(where: { $0.hasPrefix(prefix) }) else {
        return nil
    }
    let value = label.dropFirst(prefix.count)
    return value.isEmpty ? nil : String(value)
}
