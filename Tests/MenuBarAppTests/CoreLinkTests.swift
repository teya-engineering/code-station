import CodeStationCore
import Testing

// The engine is moving into the core library one batch at a time. This pins down that the
// test target is wired to it, so the migrate batches have somewhere to land.
struct CoreLinkTests {
    @Test func testTargetLinksTheCoreLibrary() {
        #expect(CodeStationCoreLibrary.name == "CodeStationCore")
    }
}
