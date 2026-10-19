import AVFoundation
import CoreAudio
import Speech
import CodeStationCore

// Why a take could not start. Each one has a next step the person can take, which the
// composer's notice row names.
enum DictationFailure: Error, Equatable {
    case microphoneBlocked
    case speechBlocked
    case languageUnsupported
    // Before macOS 26 the app cannot fetch the on-device model itself, so it can only say
    // where to get it.
    case modelMissing
    case engine(String)
}

// How far the one-time download of a language model has got.
struct DictationDownload: Equatable, Sendable {
    var fraction: Double
    var completedBytes: Int64?
    var totalBytes: Int64?
}

// A microphone the Mac can listen through.
struct AudioInput: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
}

// The speech engine as the composer sees it, so the take's handling can be tested without
// a microphone.
@MainActor
protocol SpeechSource: AnyObject {
    func allowsMicrophone() async -> Bool
    // The engine's own spelling of a language, or nil when it cannot listen in it.
    func resolve(_ locale: Locale) async -> Locale?
    func needsDownload(_ locale: Locale) async -> Bool
    func download(_ locale: Locale, progress: @escaping @MainActor (DictationDownload) -> Void) async throws
    func start(_ locale: Locale, input: AudioDeviceID?, context: [String],
               heard: @escaping @MainActor (DictationHeard) -> Void,
               level: @escaping @MainActor (Float) -> Void) async throws
    // Stops listening and waits for the engine to settle what it was still guessing at.
    func finish() async -> DictationHeard
    // Stops listening and drops everything, without waiting.
    func cancel()
}

enum DictationPermission {
    // The system asks the first time. After that only System Settings can change it.
    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func speech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let speechSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
}

enum DictationLanguages {
    static func supported() async -> [Locale] {
        if #available(macOS 26, *) {
            return await SpeechTranscriber.supportedLocales
        }
        return Array(SFSpeechRecognizer.supportedLocales())
    }

    // The engine's own spelling of a language, so "en_GB" and "en-GB" are one choice.
    static func resolve(_ locale: Locale) async -> Locale? {
        if #available(macOS 26, *) {
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
        let wanted = locale.identifier(.bcp47)
        return SFSpeechRecognizer.supportedLocales().first { $0.identifier(.bcp47) == wanted }
            ?? SFSpeechRecognizer.supportedLocales().first {
                $0.language.languageCode == locale.language.languageCode
            }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

enum AudioInputs {
    static func all() -> [AudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in name(of: id).map { AudioInput(id: id, name: $0) } }
    }

    static func current() -> AudioInput? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return name(of: id).map { AudioInput(id: id, name: $0) }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

// Listens through the microphone and turns speech into words, entirely on this Mac. No
// audio is kept: each buffer is handed to the engine and dropped.
@MainActor
final class SpeechEngine: SpeechSource {
    private var audio: AVAudioEngine?
    private var session: (any SpeechSession)?

    func allowsMicrophone() async -> Bool { await DictationPermission.microphone() }

    func resolve(_ locale: Locale) async -> Locale? { await DictationLanguages.resolve(locale) }

    func needsDownload(_ locale: Locale) async -> Bool {
        if #available(macOS 26, *) {
            let status = await AssetInventory.status(forModules: [AnalyzerSession.transcriber(locale)])
            return status != .installed && status != .unsupported
        }
        return false
    }

    func download(_ locale: Locale, progress: @escaping @MainActor (DictationDownload) -> Void) async throws {
        guard #available(macOS 26, *) else { return }
        let transcriber = AnalyzerSession.transcriber(locale)
        guard await AssetInventory.status(forModules: [transcriber]) != .unsupported else {
            throw DictationFailure.languageUnsupported
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                let report = request.progress
                // The unit count is in bytes for a download, and a small count is a plain
                // step counter that says nothing about size.
                let bytes = report.totalUnitCount > 1_000_000
                progress(DictationDownload(fraction: report.fractionCompleted,
                                           completedBytes: bytes ? report.completedUnitCount : nil,
                                           totalBytes: bytes ? report.totalUnitCount : nil))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
    }

    func start(_ locale: Locale, input: AudioDeviceID?, context: [String],
               heard: @escaping @MainActor (DictationHeard) -> Void,
               level: @escaping @MainActor (Float) -> Void) async throws {
        cancel()
        let session: any SpeechSession
        if #available(macOS 26, *) {
            session = AnalyzerSession(locale: locale)
        } else {
            guard await DictationPermission.speech() else { throw DictationFailure.speechBlocked }
            session = try RecognizerSession(locale: locale)
        }

        let audio = AVAudioEngine()
        if let input, let unit = audio.inputNode.audioUnit {
            var device = input
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = audio.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.engine("No microphone is connected.")
        }
        let feed = try await session.begin(context: context, inputFormat: format, heard: heard)
        audio.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format,
                                   block: Self.tap(feed: feed, level: level))
        audio.prepare()
        do {
            try audio.start()
        } catch {
            audio.inputNode.removeTap(onBus: 0)
            session.cancel()
            throw DictationFailure.engine(error.localizedDescription)
        }
        self.audio = audio
        self.session = session
    }

    func finish() async -> DictationHeard {
        stopAudio()
        guard let session else { return DictationHeard() }
        self.session = nil
        return await session.finish()
    }

    func cancel() {
        stopAudio()
        session?.cancel()
        session = nil
    }

    private func stopAudio() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
    }

    // Built outside the main actor: the tap runs on the audio thread, and a closure made
    // in a main-actor method would be checked against the main actor every time it ran.
    nonisolated private static func tap(feed: AudioFeed,
                                        level: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        let meter = LevelMeter()
        return { buffer, _ in
            feed.append(buffer)
            if let reading = meter.read(buffer) {
                Task { @MainActor in level(reading) }
            }
        }
    }
}

// Where the microphone's buffers go. Called on the audio thread only.
protocol AudioFeed: Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
}

@MainActor
private protocol SpeechSession: AnyObject {
    func begin(context: [String], inputFormat: AVAudioFormat,
               heard: @escaping @MainActor (DictationHeard) -> Void) async throws -> AudioFeed
    func finish() async -> DictationHeard
    func cancel()
}

// How loud the input is, about twelve times a second, on a 0 to 1 scale where ordinary
// speech sits around the middle.
private final class LevelMeter: @unchecked Sendable {
    private var last = Date.distantPast

    func read(_ buffer: AVAudioPCMBuffer) -> Float? {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.08, let samples = buffer.floatChannelData?[0] else { return nil }
        last = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let decibels = 10 * log10(max(sum / Float(count), 1e-10))
        return min(1, max(0, (decibels + 55) / 40))
    }
}

// MARK: - macOS 26 and later

@available(macOS 26, *)
@MainActor
private final class AnalyzerSession: SpeechSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var heard = DictationHeard()

    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .alternativeTranscriptions],
                          attributeOptions: [.transcriptionConfidence])
    }

    init(locale: Locale) {
        transcriber = Self.transcriber(locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func begin(context: [String], inputFormat: AVAudioFormat,
               heard update: @escaping @MainActor (DictationHeard) -> Void) async throws -> AudioFeed {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: inputFormat),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw DictationFailure.engine("The microphone's audio could not be read.")
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        if !context.isEmpty {
            let analysis = AnalysisContext()
            analysis.contextualStrings[.general] = context
            try? await analyzer.setContext(analysis)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        let transcriber = transcriber
        results = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    if result.isFinal {
                        heard.settled += Self.words(result)
                        heard.volatile = ""
                    } else {
                        heard.volatile = String(result.text.characters)
                    }
                    update(heard)
                }
            } catch {}
        }
        return ConvertingFeed(converter: converter, format: format, input: input)
    }

    func finish() async -> DictationHeard {
        input?.finish()
        input = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
        var finished = heard
        if !finished.volatile.isBlank {
            finished.settled += finished.volatile.split(whereSeparator: \.isWhitespace)
                .map { HeardWord(text: String($0)) }
        }
        finished.volatile = ""
        return finished
    }

    func cancel() {
        input?.finish()
        input = nil
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    // The confidence is carried on runs of the text, which do not line up with words, so
    // each word takes the lowest confidence of anything inside it.
    private static func words(_ result: SpeechTranscriber.Result) -> [HeardWord] {
        var best: [String] = []
        var confidences: [Double?] = []
        var current = ""
        var lowest: Double?
        func close() {
            guard !current.isEmpty else { return }
            best.append(current)
            confidences.append(lowest)
            current = ""
            lowest = nil
        }
        for run in result.text.runs {
            let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
            for character in result.text[run.range].characters {
                if character.isWhitespace {
                    close()
                } else {
                    current.append(character)
                    if let confidence { lowest = min(lowest ?? confidence, confidence) }
                }
            }
        }
        close()
        let alternatives = result.alternatives.map {
            String($0.characters).split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return DictationAlternatives.words(best: best, confidences: confidences, alternatives: alternatives)
    }
}

@available(macOS 26, *)
private final class ConvertingFeed: AudioFeed, @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.format = format
        self.input = input
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }
}

// MARK: - Before macOS 26

@MainActor
private final class RecognizerSession: SpeechSession {
    // The older engine has no settled and guessing parts of its own, so the last few
    // words of a running guess are shown as the ones still being worked out.
    nonisolated private static let guessing = 3

    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var heard = DictationHeard()
    private var finished: CheckedContinuation<Void, Never>?
    private var isFinal = false

    init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationFailure.languageUnsupported
        }
        guard recognizer.supportsOnDeviceRecognition else { throw DictationFailure.modelMissing }
        self.recognizer = recognizer
    }

    func begin(context: [String], inputFormat: AVAudioFormat,
               heard update: @escaping @MainActor (DictationHeard) -> Void) async throws -> AudioFeed {
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Array(context.prefix(100))
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result.map(Self.words)
            let final = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let words { self.heard = words }
                if final {
                    self.isFinal = true
                    self.finished?.resume()
                    self.finished = nil
                }
                update(self.heard)
            }
        }
        return RequestFeed(request: request)
    }

    func finish() async -> DictationHeard {
        request.endAudio()
        if !isFinal {
            // The last guess is good enough if the engine takes too long to settle it.
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finished?.resume()
                self?.finished = nil
            }
            await withCheckedContinuation { finished = $0 }
            timeout.cancel()
        }
        task = nil
        var settled = heard
        settled.settled += settled.volatile.split(whereSeparator: \.isWhitespace).map { HeardWord(text: String($0)) }
        settled.volatile = ""
        return settled
    }

    func cancel() {
        task?.cancel()
        task = nil
        finished?.resume()
        finished = nil
    }

    nonisolated private static func words(_ result: SFSpeechRecognitionResult) -> DictationHeard {
        let segments = result.bestTranscription.segments
        if result.isFinal {
            return DictationHeard(settled: segments.map {
                HeardWord(text: $0.substring,
                          alternatives: Double($0.confidence) < DictationAlternatives.sureEnough
                              ? $0.alternativeSubstrings : [])
            })
        }
        let split = max(0, segments.count - guessing)
        return DictationHeard(settled: segments[..<split].map { HeardWord(text: $0.substring) },
                              volatile: segments[split...].map(\.substring).joined(separator: " "))
    }
}

private final class RequestFeed: AudioFeed, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
