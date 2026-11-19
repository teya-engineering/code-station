import Testing
@testable import MenuBarApp

// Reading `docker ps` is a guess at another program's output, so the two places that
// guess could be wrong are covered here: the fields we pick out of its JSON, and the
// port list we boil down for the row.
struct DockerContainerTests {

    private let line = """
    {"Command":"\\"postgres\\"","ID":"7660d8b05f60","Image":"postgres:17-alpine",\
    "Labels":"com.docker.compose.project=code-station,com.docker.compose.service=db",\
    "Mounts":"code-station_data","Names":"code-station-db","Networks":"code-station_default",\
    "Ports":"0.0.0.0:15432->5432/tcp","Size":"12kB (virtual 420MB)","Status":"Up 2 seconds"}
    """

    @Test func readsTheFieldsTheRowShows() {
        let container = DockerContainer(line: line)
        #expect(container?.id == "7660d8b05f60")
        #expect(container?.name == "code-station-db")
        #expect(container?.image == "postgres:17-alpine")
        #expect(container?.status == "Up 2 seconds")
        #expect(container?.composeProject == "code-station")
        #expect(container?.composeService == "db")
        #expect(container?.networks == "code-station_default")
        #expect(container?.mounts == "code-station_data")
        #expect(container?.size == "12kB (virtual 420MB)")
    }

    @Test func ignoresALineThatIsNotAContainer() {
        #expect(DockerContainer(line: "") == nil)
        #expect(DockerContainer(line: "Cannot connect to the Docker daemon") == nil)
        #expect(DockerContainer(line: #"{"Names":"no-id"}"#) == nil)
    }

    // A container with no published ports still lists its exposed ones, and those have
    // no host side to show.
    @Test func keepsOnlyTheHostSideOfPublishedPorts() {
        #expect(port(in: "0.0.0.0:15432->5432/tcp") == "15432")
        #expect(port(in: "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp") == "5432")
        #expect(port(in: "0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp") == "8080, 8443")
        #expect(port(in: "5432/tcp") == "")
        #expect(port(in: "") == "")
    }

    private func port(in ports: String) -> String? {
        DockerContainer(line: #"{"ID":"abc","Ports":"\#(ports)"}"#)?.publishedPorts
    }

    @Test func readsImageDetails() {
        let line = #"{"Containers":"2","CreatedSince":"3 days ago","ID":"sha256:1234567890abcdef","Repository":"postgres","Size":"291MB","Tag":"17-alpine"}"#
        let image = DockerImage(line: line)

        #expect(image?.reference == "postgres:17-alpine")
        #expect(image?.removalTarget == "postgres:17-alpine")
        #expect(image?.shortID == "1234567890ab")
        #expect(image?.createdSince == "3 days ago")
        #expect(image?.containers == "2")
    }

    @Test func removesAnUntaggedImageByID() {
        let image = DockerImage(line: #"{"ID":"sha256:abcdef","Repository":"<none>","Tag":"<none>"}"#)

        #expect(image?.removalTarget == "sha256:abcdef")
    }

    @Test func readsNetworkDetailsAndComposeProject() {
        let line = #"{"CreatedAt":"2026-08-09 15:52:09 +0000 UTC","Driver":"bridge","ID":"92fa21892961ce","IPv6":"true","Internal":"false","Labels":"com.docker.compose.network=default,com.docker.compose.project=code-station","Name":"code-station_default","Scope":"local"}"#
        let network = DockerNetwork(line: line)

        #expect(network?.name == "code-station_default")
        #expect(network?.driver == "bridge")
        #expect(network?.composeProject == "code-station")
        #expect(network?.supportsIPv6 == true)
        #expect(network?.created == "2026-08-09 15:52:09")
    }

    @Test func readsVolumeDetailsAndComposeLabels() {
        let line = #"{"Driver":"local","Labels":"com.docker.compose.volume=postgres_data,com.docker.compose.project=code-station","Mountpoint":"/var/lib/docker/volumes/code-station_postgres_data/_data","Name":"code-station_postgres_data","Scope":"local","Size":"N/A"}"#
        let volume = DockerVolume(line: line)

        #expect(volume?.id == "code-station_postgres_data")
        #expect(volume?.composeProject == "code-station")
        #expect(volume?.composeVolume == "postgres_data")
        #expect(volume?.mountpoint == "/var/lib/docker/volumes/code-station_postgres_data/_data")
    }
}

@MainActor
struct DockerServiceTests {
    @Test func stopsEveryContainerInAComposeGroup() async throws {
        let recorder = DockerCommandRecorder()
        let service = DockerService(
            runner: { await recorder.run($0) },
            availability: { true })
        let first = try #require(DockerContainer(line:
            #"{"ID":"container-1","Labels":"com.docker.compose.project=app","Names":"app-api"}"#))
        let second = try #require(DockerContainer(line:
            #"{"ID":"container-2","Labels":"com.docker.compose.project=app","Names":"app-db"}"#))

        let failure = await service.stop([first, second])

        #expect(failure == nil)
        #expect(service.containers.busy.isEmpty)
        #expect(await recorder.commands == [
            ["stop", "container-1", "container-2"],
            ["ps", "--all", "--no-trunc", "--size", "--format", "{{json .}}"]
        ])
    }

    @Test func deletesEachDockerResourceWithItsSafeIdentifier() async throws {
        let recorder = DockerCommandRecorder()
        let service = DockerService(
            runner: { await recorder.run($0) },
            availability: { true })
        let image = try #require(DockerImage(line:
            #"{"ID":"sha256:image-id","Repository":"postgres","Tag":"17-alpine"}"#))
        let network = try #require(DockerNetwork(line:
            #"{"ID":"network-id","Name":"app_default"}"#))
        let volume = try #require(DockerVolume(line:
            #"{"Name":"app_data"}"#))

        #expect(await service.delete(image) == nil)
        #expect(await service.delete(network) == nil)
        #expect(await service.delete(volume) == nil)

        // Each removal reads its list again, then the disk use it changed.
        let disk = ["system", "df", "--format", "{{json .}}"]
        #expect(await recorder.commands == [
            ["image", "rm", "postgres:17-alpine"],
            ["image", "ls", "--no-trunc", "--format", "{{json .}}"],
            disk,
            ["network", "rm", "network-id"],
            ["network", "ls", "--no-trunc", "--format", "{{json .}}"],
            disk,
            ["volume", "rm", "app_data"],
            ["volume", "ls", "--format", "{{json .}}"],
            disk
        ])
    }

    @Test func listsContainersWithoutSizesWhenTheEngineCannotMeasureThem() async {
        let service = DockerService(
            runner: { arguments in
                // The docker CLI sizes containers for `{{json .}}` too, since it reads `.Size`.
                if arguments.first == "ps", arguments.contains("--size") || arguments.contains("{{json .}}") {
                    return DockerService.Output(errorText: "determining size of layer", status: 125)
                }
                let line = arguments.first == "ps" ? #"{"ID":"container-1","Names":"api","State":"exited"}"# : ""
                return DockerService.Output(text: line, status: 0)
            },
            availability: { true })

        await service.refresh()

        #expect(service.containers.failure == nil)
        #expect(service.containers.items.map(\.name) == ["api"])
    }

    @Test func removesStoppedContainersByIDWhenThePruneCannotMeasureThem() async {
        let recorder = DockerCommandRecorder { arguments in
            if arguments.first == "container" {
                return DockerService.Output(errorText: "determining size of layer", status: 125)
            }
            let lines = [#"{"ID":"stopped-1","Names":"api","State":"exited"}"#,
                         #"{"ID":"running-1","Names":"db","State":"running"}"#]
            return DockerService.Output(text: arguments.first == "ps" ? lines.joined(separator: "\n") : "",
                                        status: 0)
        }
        let service = DockerService(runner: { await recorder.run($0) }, availability: { true })

        let result = await service.pruneStoppedContainers()

        #expect(result.failure == nil)
        #expect(await recorder.commands.last == ["rm", "stopped-1"])
    }

    @Test func addsUpDiskUseFromTheListsWhenTheEngineCannotMeasureItself() async {
        let service = DockerService(
            runner: { arguments in
                if arguments.first == "system" {
                    return DockerService.Output(errorText: "failed to get root file system size of container 1323", status: 125)
                }
                let images = [#"{"ID":"img-1","Repository":"postgres","Tag":"18","Size":"320MB"}"#,
                              #"{"ID":"img-1","Repository":"mirror/postgres","Tag":"18","Size":"320MB"}"#,
                              #"{"ID":"img-2","Repository":"kafka","Tag":"7","Size":"1.2GB"}"#]
                let text = switch arguments.first {
                case "image": images.joined(separator: "\n")
                case "ps": #"{"ID":"container-1","Names":"api","State":"exited","Size":"5MB (virtual 325MB)"}"#
                default: ""
                }
                return DockerService.Output(text: text, status: 0)
            },
            availability: { true })

        await service.refresh(sizes: true)

        #expect(service.disk.failure == "failed to get root file system size of container 1323")
        #expect(service.disk.images == 1_520_000_000)
        #expect(service.disk.containers == 5_000_000)
        #expect(service.disk.unknown == [.volumes, .buildCache])
    }

    @Test func keepsTheSizedErrorWhenThePlainListFailsToo() async {
        let service = DockerService(
            runner: { arguments in
                let text = arguments.contains("--size") ? "Cannot connect to the Docker daemon" : "plain failed"
                return DockerService.Output(errorText: text, status: 1)
            },
            availability: { true })

        await service.refresh()

        #expect(service.containers.failure == "Cannot connect to the Docker daemon")
    }
}

private actor DockerCommandRecorder {
    private(set) var commands: [[String]] = []
    private let answer: @Sendable ([String]) -> DockerService.Output

    init(answer: @escaping @Sendable ([String]) -> DockerService.Output = { _ in DockerService.Output(status: 0) }) {
        self.answer = answer
    }

    func run(_ arguments: [String]) -> DockerService.Output {
        commands.append(arguments)
        return answer(arguments)
    }
}
