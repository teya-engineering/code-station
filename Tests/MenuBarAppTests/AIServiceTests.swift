import Testing
@testable import MenuBarApp

struct AIServiceTests {
    @Test func readsUniqueListenerPIDs() {
        #expect(AIService.listenerPIDs(from: "123\n456\n123\nnot-a-pid\n") == [123, 456])
    }

    @Test func acceptsOnlyAnExactLlamaServerPortArgument() {
        #expect(AIService.isLlamaServer(
            command: ["/opt/homebrew/bin/llama-server", "-m", "model.gguf", "--port", "8092"],
            port: 8092
        ))
        #expect(!AIService.isLlamaServer(
            command: ["/opt/homebrew/bin/llama-server-helper", "--port", "8092"],
            port: 8092
        ))
        #expect(!AIService.isLlamaServer(
            command: ["llama-server", "--port=8092"],
            port: 8092
        ))
        #expect(!AIService.isLlamaServer(
            command: ["llama-server", "--port", "80920"],
            port: 8092
        ))
    }
}
