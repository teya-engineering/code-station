import Testing
@testable import MenuBarApp

// Reading `docker ps` is a guess at another program's output, so the two places that
// guess could be wrong are covered here: the fields we pick out of its JSON, and the
// port list we boil down for the row.
struct DockerContainerTests {

    private let line = """
    {"Command":"\\"postgres\\"","ID":"7660d8b05f60","Image":"postgres:17-alpine",\
    "Names":"conductor-db","Ports":"0.0.0.0:15432->5432/tcp","Status":"Up 2 seconds"}
    """

    @Test func readsTheFieldsTheRowShows() {
        let container = DockerContainer(line: line)
        #expect(container?.id == "7660d8b05f60")
        #expect(container?.name == "conductor-db")
        #expect(container?.image == "postgres:17-alpine")
        #expect(container?.status == "Up 2 seconds")
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
}
