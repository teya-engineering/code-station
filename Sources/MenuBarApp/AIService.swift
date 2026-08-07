import Foundation
import Observation

// Owns the local llama-server process that serves the Qwen model. It runs the same
// command as the qwen25 shell alias, so the app and a terminal start the model the
// same way. Ready state comes from the server's /health endpoint rather than from
// the process being alive, because the model takes a while to load; the same probe
// also spots a server started outside the app.
@MainActor
@Observable
final class AIService {
    enum State: Equatable {
        case stopped
        case starting
        case running
        // Something answers on the port but the app did not launch it.
        case runningExternally
        case failed(String)

        var isActive: Bool {
            self == .starting || self == .running || self == .runningExternally
        }
    }

    nonisolated static let port = 8092
    nonisolated static let modelName = "Qwen 2.5 7B Instruct"
    nonisolated static let alias = "qwen25"
    nonisolated static let contextLength = 32768
    nonisolated static var endpoint: String { "http://localhost:\(port)/v1" }

    private nonisolated static var modelPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/qwen2.5-7b/Qwen2.5-7B-Instruct-Q4_K_M.gguf").path
    }

    private(set) var state: State = .stopped
    private(set) var log = ""
    private var process: Process?

    func start() {
        guard !state.isActive else { return }
        guard let executable = ProcessManager.resolve("llama-server") else {
            state = .failed("Could not find \"llama-server\" on PATH. Install it with: brew install llama.cpp")
            return
        }
        let model = Self.modelPath
        guard FileManager.default.fileExists(atPath: model) else {
            state = .failed("The model file was not found at \(model).")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-m", model,
                             "--host", "0.0.0.0",
                             "--port", "\(Self.port)",
                             "-ngl", "99",
                             "-c", "\(Self.contextLength)",
                             "--jinja",
                             "--alias", Self.alias]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        log = ""

        let service = self
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in service.appendLog(text) }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in service.processEnded(code: code) }
        }

        do {
            state = .starting
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        if process != nil {
            shutdown()
            state = .stopped
            return
        }
        // The server was started from a terminal, so the only handle on it is its
        // command line.
        await Self.killExternal()
        state = .stopped
    }

    // Quits the process the app launched, and only that one: a server someone started
    // themselves should outlive the app.
    func shutdown() {
        guard let process else { return }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        self.process = nil
    }

    // Called on a loop while the sheet is open, so the state tracks the server rather
    // than the last button press.
    func refresh() async {
        let healthy = await Self.probeHealth()
        if process != nil {
            // Loading the model can take a while; the port answering is what marks
            // the switch from starting to running.
            if healthy { state = .running }
        } else if healthy {
            state = .runningExternally
        } else if case .failed = state {
            // Keep the failure on screen until the next start attempt.
        } else {
            state = .stopped
        }
    }

    // MARK: - Private

    private func processEnded(code: Int32) {
        guard process != nil else { return }
        process = nil
        state = code == 0 ? .stopped : .failed("llama-server exited with code \(code). See output below.")
    }

    private func appendLog(_ text: String) {
        var current = log + text
        if current.count > 8000 { current = String(current.suffix(8000)) }
        log = current
    }

    // The health endpoint answers 200 only once the model is loaded and ready.
    private static func probeHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func killExternal() async {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-f", "llama-server.*--port \(port)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
    }
}
