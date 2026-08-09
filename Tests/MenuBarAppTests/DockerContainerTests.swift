import Testing
@testable import MenuBarApp

// Reading `docker ps` is a guess at another program's output, so the two places that
// guess could be wrong are covered here: the fields we pick out of its JSON, and the
// port list we boil down for the row.
struct DockerContainerTests {

    private let line = """
    {"Command":"\\"postgres\\"","ID":"7660d8b05f60","Image":"postgres:17-alpine",\
    "Labels":"com.docker.compose.project=conductor,com.docker.compose.service=db",\
    "Mounts":"conductor_data","Names":"conductor-db","Networks":"conductor_default",\
    "Ports":"0.0.0.0:15432->5432/tcp","Size":"12kB (virtual 420MB)","Status":"Up 2 seconds"}
    """

    @Test func readsTheFieldsTheRowShows() {
        let container = DockerContainer(line: line)
        #expect(container?.id == "7660d8b05f60")
        #expect(container?.name == "conductor-db")
        #expect(container?.image == "postgres:17-alpine")
        #expect(container?.status == "Up 2 seconds")
        #expect(container?.composeProject == "conductor")
        #expect(container?.composeService == "db")
        #expect(container?.networks == "conductor_default")
        #expect(container?.mounts == "conductor_data")
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
        #expect(image?.shortID == "1234567890ab")
        #expect(image?.createdSince == "3 days ago")
        #expect(image?.containers == "2")
    }

    @Test func readsNetworkDetailsAndComposeProject() {
        let line = #"{"CreatedAt":"2026-08-09 15:52:09 +0000 UTC","Driver":"bridge","ID":"92fa21892961ce","IPv6":"true","Internal":"false","Labels":"com.docker.compose.network=default,com.docker.compose.project=conductor","Name":"conductor_default","Scope":"local"}"#
        let network = DockerNetwork(line: line)

        #expect(network?.name == "conductor_default")
        #expect(network?.driver == "bridge")
        #expect(network?.composeProject == "conductor")
        #expect(network?.supportsIPv6 == true)
        #expect(network?.created == "2026-08-09 15:52:09")
    }

    @Test func readsVolumeDetailsAndComposeLabels() {
        let line = #"{"Driver":"local","Labels":"com.docker.compose.volume=postgres_data,com.docker.compose.project=conductor","Mountpoint":"/var/lib/docker/volumes/conductor_postgres_data/_data","Name":"conductor_postgres_data","Scope":"local","Size":"N/A"}"#
        let volume = DockerVolume(line: line)

        #expect(volume?.id == "conductor_postgres_data")
        #expect(volume?.composeProject == "conductor")
        #expect(volume?.composeVolume == "postgres_data")
        #expect(volume?.mountpoint == "/var/lib/docker/volumes/conductor_postgres_data/_data")
    }
}
