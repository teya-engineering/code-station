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
            ["ps", "--no-trunc", "--size", "--format", "{{json .}}"]
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

        #expect(await recorder.commands == [
            ["image", "rm", "postgres:17-alpine"],
            ["image", "ls", "--no-trunc", "--format", "{{json .}}"],
            ["network", "rm", "network-id"],
            ["network", "ls", "--no-trunc", "--format", "{{json .}}"],
            ["volume", "rm", "app_data"],
            ["volume", "ls", "--format", "{{json .}}"]
        ])
    }
}

private actor DockerCommandRecorder {
    private(set) var commands: [[String]] = []

    func run(_ arguments: [String]) -> DockerService.Output {
        commands.append(arguments)
        return DockerService.Output(status: 0)
    }
}
