import Foundation
import Observation

struct DockerContainer: Identifiable, Sendable, Equatable {
    enum State: String, Sendable {
        case running, restarting, paused, exited, created, dead, removing
    }

    let id: String
    let name: String
    let image: String
    let status: String
    let state: State
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
        // Older engines leave State out, and then the status line is the only clue.
        state = fields["State"].flatMap(State.init(rawValue:)) ?? Self.state(fromStatus: status)
    }

    private static func state(fromStatus status: String) -> State {
        if status.hasPrefix("Up") { return status.contains("(Paused)") ? .paused : .running }
        if status.hasPrefix("Restarting") { return .restarting }
        if status.hasPrefix("Created") { return .created }
        if status.hasPrefix("Dead") { return .dead }
        return .exited
    }

    var shortID: String { String(id.prefix(12)) }

    // Docker counts a paused or restarting container as running: `container prune` leaves
    // both alone, and both have to be stopped before they can be started again.
    var isRunning: Bool { state == .running || state == .restarting || state == .paused }

    // The number in "Exited (143) 2 days ago". For a restarting container it is the code
    // of the last exit, which is why it keeps coming back.
    var exitCode: Int? {
        guard let open = status.firstIndex(of: "("), let close = status.firstIndex(of: ")"),
              open < close else { return nil }
        return Int(status[status.index(after: open)..<close])
    }

    // "Up 3 hours (healthy)" says how long in its middle and how well at its end.
    var since: String {
        var text = status
        for prefix in ["Up ", "Exited ", "Restarting ", "Created ", "Paused "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = String(text[text.index(after: close)...])
        }
        if let open = text.firstIndex(of: "(") { text = String(text[..<open]) }
        return text.trimmed
    }

    var health: String? {
        if status.contains("(healthy)") { return "Healthy" }
        if status.contains("(unhealthy)") { return "Unhealthy" }
        if status.contains("health: starting") { return "Starting" }
        return nil
    }

    // The writable layer only. The "virtual" figure after it counts the image too, which
    // is shared with every other container built from it.
    var bytes: Int64? { DockerSize.bytes(size) }

    var mountNames: [String] { dockerList(mounts) }
    var networkNames: [String] { dockerList(networks) }

    // Only the published ports are worth showing, and only the host side of them:
    // "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp" says 5432 twice.
    var hostPorts: [String] {
        let ports = ports
            .split(separator: ",")
            .map { String($0).trimmed }
            .compactMap { mapping -> String? in
                guard let arrow = mapping.range(of: "->") else { return nil }
                let host = mapping[..<arrow.lowerBound]
                return host.split(separator: ":").last.map(String.init)
            }
        var seen: Set<String> = []
        return ports.filter { seen.insert($0).inserted }
    }

    var publishedPorts: String { hostPorts.joined(separator: ", ") }

    // A compose container is named after its project and service, so inside its group the
    // service alone is enough.
    var shortName: String { composeService ?? name }
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

    var isUntagged: Bool { repository == "<none>" }

    var reference: String {
        if isUntagged { return "Untagged image" }
        if tag.isEmpty || tag == "<none>" { return repository }
        return "\(repository):\(tag)"
    }

    var shortID: String {
        let value = imageID.hasPrefix("sha256:") ? String(imageID.dropFirst(7)) : imageID
        return String(value.prefix(12))
    }

    var removalTarget: String {
        isUntagged || tag.isEmpty || tag == "<none>" ? imageID : reference
    }

    var bytes: Int64? { DockerSize.bytes(size) }

    // `docker ps` names an image the way the container was started with it: by its full
    // reference, by its repository alone when the tag is "latest", or by its ID.
    func isUsed(by container: DockerContainer) -> Bool {
        let name = container.image
        if !isUntagged {
            if name == reference { return true }
            if tag == "latest", name == repository { return true }
        }
        let bare = name.hasPrefix("sha256:") ? String(name.dropFirst(7)) : name
        return bare.count >= 12 && bare.allSatisfy(\.isHexDigit) && imageID.contains(bare)
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

    // The three networks every engine starts with. Docker refuses to remove them.
    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
}

struct DockerVolume: Identifiable, Sendable, Equatable {
    let id: String
    let driver: String
    let scope: String
    let mountpoint: String
    let size: String
    let composeProject: String?
    let composeVolume: String?
    let isAnonymous: Bool

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
        // Newer engines label them. Older ones only give them a long hex name.
        isAnonymous = labels.contains("com.docker.volume.anonymous")
            || (name.count == 64 && name.allSatisfy(\.isHexDigit))
    }

    var bytes: Int64? { DockerSize.bytes(size) }

    func isUsed(by container: DockerContainer) -> Bool {
        container.mountNames.contains(id)
    }
}

// What `docker system df` says the engine holds on disk, kind by kind. The build cache has
// no list of its own, so this is the only place its size is known.
struct DockerDiskUsage: Sendable, Equatable {
    var images: Int64 = 0
    var containers: Int64 = 0
    var volumes: Int64 = 0
    var buildCache: Int64 = 0
    var buildCacheReclaimable: Int64 = 0
    var buildCacheEntries = 0
    // Set when the engine could not measure itself, so the figures above were added up from
    // the lists instead. Podman, for one, fails the whole `system df` when a single container
    // has a broken layer.
    var failure: String?
    var unknown: Set<Part> = []

    enum Part: Sendable { case images, containers, volumes, buildCache }

    var total: Int64 { images + containers + volumes + buildCache }

    init() {}

    // The lists know nothing of the build cache, and a layer shared by two images is counted
    // once for each, so this runs high when images share a base.
    init(estimatingFrom imageList: [DockerImage], containers containerList: [DockerContainer],
         volumeSizes: [String: Int64], failure: String) {
        self.failure = failure
        var imageSizes: [String: Int64] = [:]
        for image in imageList { imageSizes[image.imageID] = image.bytes ?? 0 }
        images = imageSizes.values.reduce(0, +)
        let containerSizes = containerList.compactMap(\.bytes)
        containers = containerSizes.reduce(0, +)
        volumes = volumeSizes.values.reduce(0, +)
        unknown = [.buildCache]
        if imageList.isEmpty == false, imageSizes.values.allSatisfy({ $0 == 0 }) { unknown.insert(.images) }
        if containerList.isEmpty == false, containerSizes.isEmpty { unknown.insert(.containers) }
        if volumeSizes.isEmpty { unknown.insert(.volumes) }
    }

    init(text: String) {
        for line in text.split(separator: "\n") {
            guard let fields = dockerFields(from: String(line)) else { continue }
            let size = DockerSize.bytes(fields["Size"] ?? "") ?? 0
            switch fields["Type"] {
            case "Images": images = size
            case "Containers": containers = size
            case "Local Volumes": volumes = size
            case "Build Cache":
                buildCache = size
                buildCacheReclaimable = DockerSize.bytes(fields["Reclaimable"] ?? "") ?? size
                buildCacheEntries = Int(fields["TotalCount"] ?? "") ?? 0
            default: break
            }
        }
    }
}

// Docker prints sizes the way its own `units` package does: decimal steps, a lower-case k,
// and sometimes a second figure in brackets that is not the one wanted.
enum DockerSize {
    static func bytes(_ text: String) -> Int64? {
        let first = text.split(separator: "(").first.map { String($0).trimmed } ?? ""
        guard !first.isEmpty, first != "N/A" else { return nil }
        let digits = first.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let unit = String(first.dropFirst(digits.count)).trimmed.lowercased()
        let scale: Double = switch unit {
        case "", "b": 1
        case "kb": 1e3
        case "mb": 1e6
        case "gb": 1e9
        case "tb": 1e12
        case "kib": 1024
        case "mib": 1024 * 1024
        case "gib": 1024 * 1024 * 1024
        case "tib": 1024 * 1024 * 1024 * 1024
        default: 0
        }
        guard scale > 0 else { return nil }
        return Int64((value * scale).rounded())
    }

    // Decimal steps like docker's own, and three figures at most, so "26.7 GB" fits a
    // narrow column where "26.68 GB" would not.
    static func text(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let figures = unit == 0 || value >= 99.5 ? String(Int(value.rounded()))
            : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
        return "\(figures) \(units[unit])"
    }

    // The line every prune ends with: "Total reclaimed space: 1.2GB".
    static func reclaimed(in output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("reclaimed space:") }),
              let colon = line.lastIndex(of: ":") else { return nil }
        return bytes(String(line[line.index(after: colon)...]))
    }
}

enum DockerVerb: Sendable {
    case start, stop, restart, remove

    var progress: String {
        switch self {
        case .start: "Starting…"
        case .stop: "Stopping…"
        case .restart: "Restarting…"
        case .remove: "Deleting…"
        }
    }

    var past: String {
        switch self {
        case .start: "Started"
        case .stop: "Stopped"
        case .restart: "Restarted"
        case .remove: "Deleted"
        }
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
        // A plainer form of `list` to ask for when `list` fails, for an engine that is up
        // but cannot answer the full question.
        let fallback: [String]?
        let parse: @Sendable (String) -> Item?
        let sortKey: @Sendable (Item) -> String

        init(list: [String], fallback: [String]? = nil, parse: @escaping @Sendable (String) -> Item?,
             sortKey: @escaping @Sendable (Item) -> String) {
            self.list = list
            self.fallback = fallback
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
        list: ["ps", "--all", "--no-trunc", "--size", "--format", "{{json .}}"],
        // Podman fails the whole list when it cannot measure one container's layers, so
        // the list without sizes is still better than calling the engine stopped. The fields
        // are named one by one because `{{json .}}` touches `.Size`, and the docker CLI then
        // asks for sizes even without `--size`.
        fallback: ["ps", "--all", "--no-trunc", "--format",
                   #"{"ID":{{json .ID}},"Names":{{json .Names}},"Image":{{json .Image}},"Status":{{json .Status}},"State":{{json .State}},"Ports":{{json .Ports}},"Networks":{{json .Networks}},"Mounts":{{json .Mounts}},"Labels":{{json .Labels}}}"#],
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
    private(set) var disk = DockerDiskUsage()
    // `volume ls` leaves sizes out, so they come from the verbose `system df`, which walks
    // every volume and is only asked for on a full refresh.
    private(set) var volumeSizes: [String: Int64] = [:]
    // What each container is going through, so its row can say so while docker works.
    private(set) var working: [String: DockerVerb] = [:]

    var isAvailable: Bool { availability() }
    var runningCount: Int { containers.items.count(where: \.isRunning) }

    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let availability: Availability

    init(runner: Runner? = nil, availability: Availability? = nil) {
        self.runner = runner ?? Self.run
        self.availability = availability ?? { ProcessManager.resolve("docker") != nil }
    }

    // Sizes cost docker a walk over every volume, so only the Docker sheet, which shows
    // them, asks for them.
    func refresh(sizes: Bool = false) async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }

        async let containerResult = Self.read(containers, with: runner)
        async let imageResult = Self.read(images, with: runner)
        async let networkResult = Self.read(networks, with: runner)
        async let volumeResult = Self.read(volumes, with: runner)

        let results = await (containerResult, imageResult, networkResult, volumeResult)
        containers.apply(results.0)
        images.apply(results.1)
        networks.apply(results.2)
        volumes.apply(results.3)

        guard sizes, containers.failure == nil else { return }
        async let diskResult = runner(Self.diskUsage)
        async let volumeSizeResult = runner(Self.verboseDiskUsage)
        applyVolumeSizes(await volumeSizeResult)
        applyDisk(await diskResult)
    }

    func refreshContainers() async {
        guard isAvailable else {
            dockerUnavailable()
            return
        }
        await refresh(\.containers)
    }

    // MARK: - Containers

    // Docker asks a container to quit and only kills it if it will not, so a stop can sit
    // for a few seconds on a container that ignores the signal. A container already being
    // worked on is left out rather than queued.
    func perform(_ verb: DockerVerb, on containers: [DockerContainer]) async -> String? {
        let ids = containers.map(\.id).filter { working[$0] == nil }
        guard !ids.isEmpty else { return nil }

        for id in ids { working[id] = verb }
        let command = switch verb {
        case .start: ["start"]
        case .stop: ["stop"]
        case .restart: ["restart"]
        case .remove: ["rm", "--force"]
        }
        let result = await runner(command + ids)
        for id in ids { working[id] = nil }
        await refreshContainers()
        if verb == .remove { await refreshDisk() }
        return result.ok ? nil : result.failureMessage
    }

    // Compose knows the order its services depend on each other, so a whole project is
    // started and stopped through it rather than container by container.
    func compose(_ verb: DockerVerb, project: String, containers: [DockerContainer]) async -> String? {
        guard verb == .start || verb == .stop else { return await perform(verb, on: containers) }
        let ids = containers.map(\.id).filter { working[$0] == nil }
        guard !ids.isEmpty else { return nil }

        for id in ids { working[id] = verb }
        let result = await runner(["compose", "--project-name", project, verb == .start ? "start" : "stop"])
        for id in ids { working[id] = nil }
        await refreshContainers()
        return result.ok ? nil : result.failureMessage
    }

    // MARK: - Deleting

    // Each item goes in a command of its own, so one that docker refuses does not stop the
    // rest and its own complaint can be shown beside its name. Returns docker's words for
    // every item it refused, keyed by the item's ID.
    func delete(_ images: [DockerImage], force: Bool = false) async -> [String: String] {
        await delete(images, from: \.images) { ["image", "rm"] + (force ? ["--force"] : []) + [$0.removalTarget] }
    }

    func delete(_ networks: [DockerNetwork]) async -> [String: String] {
        await delete(networks, from: \.networks) { ["network", "rm", $0.id] }
    }

    func delete(_ volumes: [DockerVolume]) async -> [String: String] {
        await delete(volumes, from: \.volumes) { ["volume", "rm", $0.id] }
    }

    func delete(_ image: DockerImage) async -> String? {
        await delete([image]).values.first
    }

    func delete(_ network: DockerNetwork) async -> String? {
        await delete([network]).values.first
    }

    func delete(_ volume: DockerVolume) async -> String? {
        await delete([volume]).values.first
    }

    // A second click while docker is still removing something is ignored rather than
    // queued. The list is read again afterwards so the screen shows what is left.
    private func delete<Item>(_ items: [Item],
                              from resource: ReferenceWritableKeyPath<DockerService, Resource<Item>>,
                              command: (Item) -> [String]) async -> [String: String] where Item.ID == String {
        let items = items.filter { !self[keyPath: resource].busy.contains($0.id) }
        guard !items.isEmpty else { return [:] }
        self[keyPath: resource].busy.formUnion(items.map(\.id))

        var failures: [String: String] = [:]
        for item in items {
            let result = await runner(command(item))
            if !result.ok { failures[item.id] = result.failureMessage }
        }
        self[keyPath: resource].busy.subtract(items.map(\.id))
        if failures.count < items.count {
            await refresh(resource)
            await refreshDisk()
        }
        return failures
    }

    // MARK: - Clean up

    // Runs one step of a clean up and says how much docker reports it freed.
    func prune(_ arguments: [String]) async -> (freed: Int64?, failure: String?) {
        let result = await runner(arguments)
        guard result.ok else { return (nil, result.failureMessage) }
        return (DockerSize.reclaimed(in: result.text), nil)
    }

    // Podman measures each stopped container before it prunes it, and keeps any it cannot
    // measure, so a container with a broken layer would never go. `rm` does not measure,
    // and without `--force` it still leaves a container alone if it has started since.
    func pruneStoppedContainers() async -> (freed: Int64?, failure: String?) {
        let pruned = await prune(DockerCleanUp.Choice.stoppedContainers.command)
        guard pruned.failure != nil else { return pruned }
        await refreshContainers()
        let stopped = containers.items.filter { !$0.isRunning }.map(\.id)
        guard !stopped.isEmpty else { return (nil, nil) }
        let removed = await runner(["rm"] + stopped)
        return removed.ok ? (nil, nil) : (nil, removed.failureMessage)
    }

    // MARK: - Reading

    private static let diskUsage = ["system", "df", "--format", "{{json .}}"]
    private static let verboseDiskUsage = ["system", "df", "--verbose", "--format", "{{json .}}"]

    func refreshDisk() async {
        guard isAvailable else { return }
        applyDisk(await runner(Self.diskUsage))
    }

    private func applyDisk(_ result: Output) {
        disk = result.ok ? DockerDiskUsage(text: result.text)
            : DockerDiskUsage(estimatingFrom: images.items, containers: containers.items,
                              volumeSizes: volumeSizes, failure: result.failureMessage)
    }

    // The verbose form is one object rather than a line per kind, and only its volume
    // sizes are read. Anything else it says is already known from the lists.
    private func applyVolumeSizes(_ result: Output) {
        guard result.ok, let data = result.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]] else { return }
        var sizes: [String: Int64] = [:]
        for volume in volumes {
            guard let name = volume["Name"] as? String,
                  let size = (volume["Size"] as? String).flatMap(DockerSize.bytes) else { continue }
            sizes[name] = size
        }
        volumeSizes = sizes
    }

    private func refresh<Item>(_ resource: ReferenceWritableKeyPath<DockerService, Resource<Item>>) async {
        let result = await Self.read(self[keyPath: resource], with: runner)
        self[keyPath: resource].apply(result)
    }

    nonisolated private static func read<Item>(_ resource: Resource<Item>, with runner: Runner) async -> Output {
        let result = await runner(resource.list)
        guard !result.ok, let fallback = resource.fallback else { return result }
        let plain = await runner(fallback)
        return plain.ok ? plain : result
    }

    private func dockerUnavailable() {
        let missing = Output(errorText: "Docker was not found. Install Docker Desktop, Rancher Desktop or Podman, or start it if it is already installed.")
        containers.apply(missing)
        images.apply(missing)
        networks.apply(missing)
        volumes.apply(missing)
    }

    // MARK: - Running docker

    nonisolated private static func run(_ arguments: [String]) async -> Output {
        if arguments.first == "compose" {
            return await runCompose(Array(arguments.dropFirst()), with: execute)
        }
        return await execute("docker", arguments) ?? Output(errorText: "Docker was not found on PATH.")
    }

    // Compose comes in more than one shape. Docker Desktop ships it as a `docker compose`
    // plugin, while Homebrew, Rancher Desktop and Podman setups often have only the
    // standalone `docker-compose`, or a plugin link left pointing at a tool since removed.
    // The plugin is tried first, and only when docker cannot run it at all is the next
    // shape tried, so a real failure from compose itself is reported as it is.
    nonisolated static func runCompose(_ arguments: [String],
                                       with execute: @Sendable (String, [String]) async -> Output?) async -> Output {
        let plugin = await execute("docker", ["compose"] + arguments)
        if let plugin, plugin.ok { return plugin }
        if let plugin, await execute("docker", ["compose", "version"])?.ok == true { return plugin }

        if let standalone = await execute("docker-compose", arguments) { return standalone }
        if let podman = await execute("podman", ["compose"] + arguments) { return podman }
        return Output(errorText: "Docker Compose was not found. Install the compose plugin or the standalone docker-compose.")
    }

    // Returns nil when the tool is not installed, so a caller can try another one.
    nonisolated private static func execute(_ tool: String, _ arguments: [String]) async -> Output? {
        guard let path = ProcessManager.resolve(tool) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath

        do {
            // A prune of a large build cache can take a while, and cutting it off half way
            // leaves the user guessing what went.
            let output = try await CommandRunner.run(
                executable: path,
                arguments: arguments,
                environment: environment,
                timeout: arguments.contains("prune") ? .seconds(600) : .seconds(30)
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

private func dockerList(_ text: String) -> [String] {
    text.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
}
