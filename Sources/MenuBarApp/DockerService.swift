import Foundation
import Observation

struct DockerContainer: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let image: String
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
            .map { String($0).trimmed }
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

    var removalTarget: String {
        repository == "<none>" || tag.isEmpty || tag == "<none>" ? imageID : reference
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
    struct Output: Sendable {
        var text = ""
        var errorText = ""
        var status: Int32 = -1

        var ok: Bool { status == 0 }
        var failureMessage: String {
            errorText.isBlank ? "docker exited with code \(status)." : errorText.trimmed
        }
    }

    // One kind of thing docker lists. Containers, images, networks and volumes are all
    // read, failed and shown the same way, so what differs between them is kept to the
    // `ls` command, the line parser and the sort key. Sendable because the lists are
    // read from the child tasks that run the four commands side by side.
    struct Resource<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
        var items: [Item] = []
        var failure: String?
        // False until the first answer, so a tab can say it is still looking rather
        // than that there is nothing there.
        var hasLoaded = false
        // The items docker is working on right now: a container being stopped, an
        // image being removed.
        var busy: Set<Item.ID> = []
        let list: [String]
        let parse: @Sendable (String) -> Item?
        let sortKey: @Sendable (Item) -> String

        init(list: [String], parse: @escaping @Sendable (String) -> Item?,
             sortKey: @escaping @Sendable (Item) -> String) {
            self.list = list
            self.parse = parse
            self.sortKey = sortKey
        }

        mutating func apply(_ result: Output) {
            hasLoaded = true
            guard result.ok else {
                items = []
                failure = result.failureMessage
                return
            }
            failure = nil
            items = result.text
                .split(separator: "\n")
                .compactMap { parse(String($0)) }
                .sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
        }
    }

    typealias Runner = @Sendable ([String]) async -> Output
    typealias Availability = @Sendable () -> Bool

    private(set) var containers = Resource<DockerContainer>(
        list: ["ps", "--no-trunc", "--size", "--format", "{{json .}}"],
        parse: DockerContainer.init(line:), sortKey: \.name)
    private(set) var images = Resource<DockerImage>(
        list: ["image", "ls", "--no-trunc", "--format", "{{json .}}"],
        parse: DockerImage.init(line:), sortKey: \.reference)
    private(set) var networks = Resource<DockerNetwork>(
        list: ["network", "ls", "--no-trunc", "--format", "{{json .}}"],
        parse: DockerNetwork.init(line:), sortKey: \.name)
    private(set) var volumes = Resource<DockerVolume>(
        list: ["volume", "ls", "--format", "{{json .}}"],
        parse: DockerVolume.init(line:), sortKey: \.id)

    var isAvailable: Bool { availability() }

    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let availability: Availability

    init(runner: Runner? = nil, availability: Availability? = nil) {
        self.runner = runner ?? Self.run
        self.availability = availability ?? { ProcessManager.resolve("docker") != nil }
    }

    func refresh() async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }

        async let containerResult = runner(containers.list)
        async let imageResult = runner(images.list)
        async let networkResult = runner(networks.list)
        async let volumeResult = runner(volumes.list)

        let results = await (containerResult, imageResult, networkResult, volumeResult)
        containers.apply(results.0)
        images.apply(results.1)
        networks.apply(results.2)
        volumes.apply(results.3)
    }

    func refreshContainers() async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }
        await refresh(\.containers)
    }

    // Docker asks the container to quit and only kills it if it will not, so this can
    // sit for a few seconds on a container that ignores the signal.
    func stop(_ containers: [DockerContainer]) async -> String? {
        let containers = containers.filter { !self.containers.busy.contains($0.id) }
        guard !containers.isEmpty else { return nil }

        let ids = containers.map(\.id)
        self.containers.busy.formUnion(ids)
        let result = await runner(["stop"] + ids)
        self.containers.busy.subtract(ids)
        await refreshContainers()

        if !result.ok {
            return result.failureMessage
        }
        return nil
    }

    func delete(_ image: DockerImage) async -> String? {
        await delete(image.id, from: \.images, arguments: ["image", "rm", image.removalTarget])
    }

    func delete(_ network: DockerNetwork) async -> String? {
        await delete(network.id, from: \.networks, arguments: ["network", "rm", network.id])
    }

    func delete(_ volume: DockerVolume) async -> String? {
        await delete(volume.id, from: \.volumes, arguments: ["volume", "rm", volume.id])
    }

    // A second click while docker is still removing something is ignored rather than
    // queued. The list is read again afterwards so the screen shows what is left.
    private func delete<Item>(_ id: Item.ID,
                              from resource: ReferenceWritableKeyPath<DockerService, Resource<Item>>,
                              arguments: [String]) async -> String? {
        guard self[keyPath: resource].busy.insert(id).inserted else { return nil }
        defer { self[keyPath: resource].busy.remove(id) }

        let result = await runner(arguments)
        guard result.ok else { return result.failureMessage }
        await refresh(resource)
        return nil
    }

    private func refresh<Item>(_ resource: ReferenceWritableKeyPath<DockerService, Resource<Item>>) async {
        let result = await runner(self[keyPath: resource].list)
        self[keyPath: resource].apply(result)
    }

    private func dockerUnavailable() {
        let missing = Output(errorText: "Docker was not found. Install Docker Desktop, or start it if it is already installed.")
        containers.apply(missing)
        images.apply(missing)
        networks.apply(missing)
        volumes.apply(missing)
    }

    // MARK: - Running docker

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
