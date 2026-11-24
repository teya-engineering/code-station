import Testing
@testable import MenuBarApp

// The `docker` CLI can sit in front of different engines, and each answers the same command
// in its own way. Each engine here replays the answers it gives, so the whole Docker sheet
// is read the same way the app reads it on a real Mac.
@MainActor
struct DockerEngineTests {
    @Test(arguments: Engine.all)
    func readsEveryList(engine: Engine) async {
        let service = DockerService(runner: engine.answer, availability: { true })

        await service.refresh(sizes: true)

        #expect(service.containers.failure == nil)
        #expect(service.containers.items.map(\.name) == ["api", "db"])
        #expect(service.images.items.count == 2)
        #expect(service.volumes.items.map(\.id) == ["pgdata"])
        #expect(service.networks.items.map(\.name).sorted() == ["app_default", "bridge"])
    }

    @Test(arguments: Engine.all)
    func measuresDiskUse(engine: Engine) async {
        let service = DockerService(runner: engine.answer, availability: { true })

        await service.refresh(sizes: true)

        #expect(service.disk.images == engine.expected.images)
        #expect(service.disk.volumes == engine.expected.volumes)
        #expect(service.disk.buildCache == engine.expected.buildCache)
        #expect(service.disk.unknown == engine.expected.unknown)
        #expect((service.disk.failure != nil) == engine.expected.estimated)
    }

    @Test func podmanWithABrokenLayerStillListsContainersWithoutSizes() async {
        let service = DockerService(runner: Engine.podmanWithBrokenLayer.answer, availability: { true })

        await service.refresh(sizes: true)

        #expect(service.containers.items.allSatisfy { $0.bytes == nil })
        #expect(service.disk.failure?.contains("failed to get root file system size") == true)
    }
}

struct Engine: Sendable, CustomTestStringConvertible {
    struct Expected: Sendable {
        var images: Int64
        var volumes: Int64
        var buildCache: Int64
        var unknown: Set<DockerDiskUsage.Part> = []
        var estimated = false
    }

    let name: String
    let expected: Expected
    let answer: @Sendable ([String]) async -> DockerService.Output

    var testDescription: String { name }

    static let all = [dockerDesktop, rancherDesktop, dockerEngine, podman, podmanWithBrokenLayer]

    // Docker Desktop runs moby in its own VM and keeps a BuildKit cache.
    static let dockerDesktop = moby(
        name: "Docker Desktop",
        df: [#"{"Active":"2","Reclaimable":"0B (0%)","Size":"1.52GB","TotalCount":"2","Type":"Images"}"#,
             #"{"Active":"1","Reclaimable":"5MB (100%)","Size":"5MB","TotalCount":"2","Type":"Containers"}"#,
             #"{"Active":"1","Reclaimable":"0B (0%)","Size":"48MB","TotalCount":"1","Type":"Local Volumes"}"#,
             #"{"Active":"0","Reclaimable":"1.1GB","Size":"2.3GB","TotalCount":"212","Type":"Build Cache"}"#],
        expected: Expected(images: 1_520_000_000, volumes: 48_000_000, buildCache: 2_300_000_000))

    // Rancher Desktop in dockerd mode is moby too, but in a Lima VM with sizes in kB.
    static let rancherDesktop = moby(
        name: "Rancher Desktop",
        df: [#"{"Active":"2","Reclaimable":"0B (0%)","Size":"1.52GB","TotalCount":"2","Type":"Images"}"#,
             #"{"Active":"1","Reclaimable":"5MB (100%)","Size":"5MB","TotalCount":"2","Type":"Containers"}"#,
             #"{"Active":"1","Reclaimable":"0B (0%)","Size":"48MB","TotalCount":"1","Type":"Local Volumes"}"#,
             #"{"Active":"0","Reclaimable":"812.4kB","Size":"812.4kB","TotalCount":"3","Type":"Build Cache"}"#],
        expected: Expected(images: 1_520_000_000, volumes: 48_000_000, buildCache: 812_400))

    // A plain engine, as Colima and OrbStack run, with nothing built yet.
    static let dockerEngine = moby(
        name: "Docker Engine",
        df: [#"{"Active":"2","Reclaimable":"0B (0%)","Size":"1.52GB","TotalCount":"2","Type":"Images"}"#,
             #"{"Active":"1","Reclaimable":"5MB (100%)","Size":"5MB","TotalCount":"2","Type":"Containers"}"#,
             #"{"Active":"1","Reclaimable":"0B (0%)","Size":"48MB","TotalCount":"1","Type":"Local Volumes"}"#,
             #"{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}"#],
        expected: Expected(images: 1_520_000_000, volumes: 48_000_000, buildCache: 0))

    // Podman's docker socket. Image IDs come back with their `sha256:` prefix, and volume
    // and network lists fill fields they have no value for with "N/A".
    static let podman = Engine(
        name: "Podman",
        expected: Expected(images: 1_520_000_000, volumes: 48_000_000, buildCache: 0)) { arguments in
        switch arguments.first {
        case "system":
            if arguments.contains("--verbose") { return ok(verboseDisk) }
            return ok([#"{"Active":"2","Reclaimable":"0B (0%)","Size":"1.52GB","TotalCount":"2","Type":"Images"}"#,
                       #"{"Active":"1","Reclaimable":"5MB (100%)","Size":"5MB","TotalCount":"2","Type":"Containers"}"#,
                       #"{"Active":"1","Reclaimable":"0B (0%)","Size":"48MB","TotalCount":"1","Type":"Local Volumes"}"#,
                       #"{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}"#]
                .joined(separator: "\n"))
        default: return podmanList(arguments)
        }
    }

    // Podman fails the whole `system df`, and any `ps` that asks for sizes, when it cannot
    // measure a single container. This is the error a real machine gave.
    static let podmanWithBrokenLayer = Engine(
        name: "Podman with a broken layer",
        expected: Expected(images: 1_520_000_000, volumes: 0, buildCache: 0,
                           unknown: [.containers, .volumes, .buildCache], estimated: true)) { arguments in
        let broken = DockerService.Output(
            errorText: #"Error response from daemon: failed to get root file system size of container 1323e91ed906: determining size of layer with ID "6e6b78d54f30": can't stat (or find?) lower layer "/var/lib/containers/storage/overlay/diff""#,
            status: 1)
        if arguments.first == "system" { return broken }
        if arguments.first == "ps", arguments.contains("--size") || arguments.contains("{{json .}}") { return broken }
        return podmanList(arguments)
    }

    private static func moby(name: String, df: [String], expected: Expected) -> Engine {
        Engine(name: name, expected: expected) { arguments in
            switch arguments.first {
            case "system": ok(arguments.contains("--verbose") ? verboseDisk : df.joined(separator: "\n"))
            case "ps": ok(containers)
            case "image": ok([#"{"Containers":"1","CreatedSince":"3 weeks ago","ID":"sha256:aaa","Repository":"postgres","Size":"320MB","Tag":"18"}"#,
                              #"{"Containers":"1","CreatedSince":"2 years ago","ID":"sha256:bbb","Repository":"kafka","Size":"1.2GB","Tag":"7"}"#]
                .joined(separator: "\n"))
            case "volume": ok(#"{"Driver":"local","Labels":"","Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Scope":"local","Size":"N/A"}"#)
            case "network": ok([#"{"Driver":"bridge","ID":"n1","Name":"bridge","Scope":"local"}"#,
                                #"{"Driver":"bridge","ID":"n2","Name":"app_default","Scope":"local"}"#]
                .joined(separator: "\n"))
            default: ok("")
            }
        }
    }

    private static func podmanList(_ arguments: [String]) -> DockerService.Output {
        switch arguments.first {
        case "ps":
            if arguments.contains("--size") || arguments.contains("{{json .}}") { return ok(containers) }
            return ok([#"{"ID":"c1","Names":"api","Image":"api:latest","Status":"Exited (0) 3 weeks ago","State":"exited","Ports":"","Networks":"","Mounts":"","Labels":""}"#,
                       #"{"ID":"c2","Names":"db","Image":"postgres:18","Status":"Up 2 hours","State":"running","Ports":"","Networks":"","Mounts":"pgdata","Labels":""}"#]
                .joined(separator: "\n"))
        case "image":
            return ok([#"{"Containers":"1","CreatedSince":"3 weeks ago","Digest":"<none>","ID":"sha256:69a93763f414","Repository":"postgres","SharedSize":"N/A","Size":"320MB","Tag":"18","UniqueSize":"N/A"}"#,
                       #"{"Containers":"1","CreatedSince":"2 years ago","Digest":"<none>","ID":"sha256:bfe12015a4bd","Repository":"kafka","SharedSize":"N/A","Size":"1.2GB","Tag":"7","UniqueSize":"N/A"}"#]
                .joined(separator: "\n"))
        case "volume":
            return ok(#"{"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/containers/storage/volumes/pgdata/_data","Name":"pgdata","Scope":"local","Size":"N/A","Status":"N/A"}"#)
        case "network":
            return ok([#"{"Driver":"bridge","ID":"n1","IPv4":"true","IPv6":"false","Internal":"false","Labels":"","Name":"bridge","Scope":"local"}"#,
                       #"{"Driver":"bridge","ID":"n2","IPv4":"true","IPv6":"false","Internal":"false","Labels":"","Name":"app_default","Scope":"local"}"#]
                .joined(separator: "\n"))
        default:
            return ok("")
        }
    }

    private static let containers = [
        #"{"ID":"c1","Names":"api","Image":"api:latest","Status":"Exited (0) 3 weeks ago","State":"exited","Size":"5MB (virtual 325MB)"}"#,
        #"{"ID":"c2","Names":"db","Image":"postgres:18","Status":"Up 2 hours","State":"running","Mounts":"pgdata","Size":"0B (virtual 320MB)"}"#
    ].joined(separator: "\n")

    private static let verboseDisk = #"{"Images":[],"Containers":[],"Volumes":[{"Name":"pgdata","Size":"48MB","Links":"1"}],"BuildCache":[]}"#

    private static func ok(_ text: String) -> DockerService.Output {
        DockerService.Output(text: text, status: 0)
    }
}
