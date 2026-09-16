import XCTest
@testable import OatmealCore

final class TranscriptionTests: XCTestCase {
    func testWAVEncoderWritesMonoSixteenBitPCMHeader() throws {
        let chunk = CapturedAudioChunk(source: .microphone, startMS: 0, sampleRate: 16_000, channels: 1, samples: [-1, 0, 1])

        let data = try WAVEncoder.encode(chunk)

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + 6)
    }

    func testWindowAssemblerSeparatesSourcesAndBoundsBacklog() async {
        let assembler = AudioWindowAssembler(windowSamples: 4, maximumSamplesPerSource: 6)
        let microphone = CapturedAudioChunk(source: .microphone, startMS: 1, sampleRate: 16_000, channels: 1, samples: [1, 2, 3])
        let system = CapturedAudioChunk(source: .system, startMS: 2, sampleRate: 16_000, channels: 1, samples: [4, 5, 6, 7])

        let microphoneWindows = await assembler.append(microphone)
        XCTAssertEqual(microphoneWindows, [])
        let systemWindows = await assembler.append(system)
        XCTAssertEqual(systemWindows.first?.source, .system)
        XCTAssertEqual(systemWindows.first?.samples, [4, 5, 6, 7])
        _ = await assembler.append(.init(source: .microphone, startMS: 3, sampleRate: 16_000, channels: 1, samples: [4, 5, 6, 7, 8, 9, 10]))

        let pending = await assembler.pendingSampleCount
        XCTAssertLessThan(pending, 4)
    }

    func testCoordinatorShowsPartialButPersistsOnlyFinalSourceLabeledText() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        let engine = FixtureTranscriptionEngine(results: [1: .success("hello")], partials: [1: "hel"])
        let coordinator = TranscriptionCoordinator(engine: engine, store: store)
        let partials = StringCollector()

        let segment = try await coordinator.transcribe(
            .init(source: .microphone, startMS: 1, sampleRate: 16_000, channels: 1, samples: [0.1]),
            meetingID: meeting.id,
            partial: { text in Task { await partials.append(text) } }
        )
        try await Task.sleep(nanoseconds: 10_000_000)

        let displayedPartials = await partials.values
        XCTAssertEqual(segment?.source, .me)
        XCTAssertEqual(displayedPartials, ["hel"])
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["hello"])
    }

    func testCoordinatorIgnoresSilenceAndLowSteadyNoiseFromBothSources() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        let engine = FixtureTranscriptionEngine(results: [0: .success("hallucination"), 40: .success("hallucination")])
        let coordinator = TranscriptionCoordinator(engine: engine, store: store)
        let partials = StringCollector()

        let silence: TranscriptSegment? = try await coordinator.transcribe(
            CapturedAudioChunk(source: .microphone, startMS: 0, sampleRate: 16_000, channels: 1, samples: Array(repeating: 0, count: 640)),
            meetingID: meeting.id,
            partial: { text in Task { await partials.append(text) } }
        )
        let noise: TranscriptSegment? = try await coordinator.transcribe(
            CapturedAudioChunk(source: .system, startMS: 40, sampleRate: 16_000, channels: 1, samples: Array(repeating: 0.001, count: 640)),
            meetingID: meeting.id,
            partial: { text in Task { await partials.append(text) } }
        )
        let callCount = await engine.callCount
        let displayedPartials = await partials.values
        let status = await coordinator.status

        XCTAssertNil(silence)
        XCTAssertNil(noise)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(displayedPartials, [])
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript, [])
        XCTAssertEqual(status, .ready)
    }

    func testCoordinatorTranscribesQuietSpeechAfterSilence() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        let engine = FixtureTranscriptionEngine(results: [0: .success("Quiet speech")])
        let coordinator = TranscriptionCoordinator(engine: engine, store: store)
        let samples = Array(repeating: Float.zero, count: 320) + (0..<320).map { index in
            Float(sin(Double(index) * .pi / 8)) * 0.02
        }

        let segment: TranscriptSegment? = try await coordinator.transcribe(
            CapturedAudioChunk(source: .microphone, startMS: 0, sampleRate: 16_000, channels: 1, samples: samples),
            meetingID: meeting.id
        )
        let callCount = await engine.callCount

        XCTAssertEqual(segment?.text, "Quiet speech")
        XCTAssertEqual(segment?.source, .me)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["Quiet speech"])
    }

    func testOutOfOrderInferenceCompletionReadsInMeetingTimeOrder() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        let engine = FixtureTranscriptionEngine(
            results: [20: .success("Later"), 5: .success("Earlier")],
            delays: [20: 1_000_000, 5: 20_000_000]
        )
        let coordinator = TranscriptionCoordinator(engine: engine, store: store)

        async let later = coordinator.transcribe(.fixture(source: .system, startMS: 20), meetingID: meeting.id)
        async let earlier = coordinator.transcribe(.fixture(source: .microphone, startMS: 5), meetingID: meeting.id)
        _ = try await [later, earlier]

        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["Earlier", "Later"])
    }

    func testInferenceFailureLeavesPriorFinalTextReadable() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        let engine = FixtureTranscriptionEngine(results: [1: .success("Kept"), 2: .failure(FixtureError.failed)])
        let coordinator = TranscriptionCoordinator(engine: engine, store: store)

        _ = try await coordinator.transcribe(.fixture(source: .microphone, startMS: 1), meetingID: meeting.id)
        do {
            _ = try await coordinator.transcribe(.fixture(source: .system, startMS: 2), meetingID: meeting.id)
            XCTFail("Expected inference failure")
        } catch {
            XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["Kept"])
        }
    }

    func testServerEngineStartsEachSourceRuntimeOnceAndReusesItAcrossWindows() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })

        try await engine.validateModel()
        _ = try await engine.transcribe(.fixture(source: .microphone, startMS: 0), partial: { _ in })
        _ = try await engine.transcribe(.fixture(source: .microphone, startMS: 1), partial: { _ in })
        _ = try await engine.transcribe(.fixture(source: .system, startMS: 0), partial: { _ in })
        try await engine.validateModel() // a second meeting starting with the same model

        XCTAssertEqual(launcher.launches, [.microphone, .system])
    }

    func testServerEngineRoutesEachSourceToItsOwnRuntime() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })
        try await engine.validateModel()

        let microphoneText = try await engine.transcribe(.fixture(source: .microphone, startMS: 0), partial: { _ in })
        let systemText = try await engine.transcribe(.fixture(source: .system, startMS: 0), partial: { _ in })

        XCTAssertEqual(microphoneText, "microphone-1")
        XCTAssertEqual(systemText, "system-1")
    }

    func testServerEngineSharesInFlightPreparationAcrossConcurrentCallers() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        launcher.setReadyDelay(nanoseconds: 100_000_000)
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })

        async let first: String = engine.transcribe(.fixture(source: .microphone, startMS: 0), partial: { _ in })
        async let second: String = engine.transcribe(.fixture(source: .microphone, startMS: 1), partial: { _ in })
        _ = try await (first, second)

        XCTAssertEqual(launcher.launches, [.microphone])
    }

    func testServerProcessArgumentsBindOnlyToLoopback() {
        let arguments = ProcessWhisperRuntime.serverArguments(modelPath: "/models/small.bin", port: 4_123)

        XCTAssertEqual(arguments, ["--no-gpu", "-m", "/models/small.bin", "--host", "127.0.0.1", "--port", "4123"])
    }

    func testServerEngineSurfacesStartupFailureAndRetriesOnNextPreparation() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        launcher.setReadyError(FixtureError.failed)
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })

        do {
            try await engine.validateModel()
            XCTFail("Expected startup failure")
        } catch {}
        XCTAssertEqual(launcher.launchCount, 2)

        launcher.setReadyError(nil)
        try await engine.validateModel()
        XCTAssertEqual(launcher.launchCount, 4)
    }

    func testServerEngineCancellationStopsRequestWithoutStoppingRuntime() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })
        try await engine.validateModel()

        let task = Task { try await engine.transcribe(.fixture(source: .microphone, startMS: 0), partial: { _ in }) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Expected CancellationError, got \(error)") }

        let runtime = try XCTUnwrap(launcher.runtimes[.microphone])
        XCTAssertTrue(runtime.isRunning)
        XCTAssertFalse(runtime.terminated)
    }

    func testServerEngineShutdownTerminatesAllRuntimes() async throws {
        let launcher = FakeWhisperRuntimeLauncher()
        let engine = WhisperServerEngine(modelURL: try modelFile(), launch: { source, url in try launcher.launch(source, url) })
        try await engine.validateModel()

        engine.shutdown()

        for source in AudioSource.allCases {
            let runtime = try XCTUnwrap(launcher.runtimes[source])
            XCTAssertTrue(runtime.terminated)
        }
    }

    func testRealWhisperServerFixtureWhenConfigured() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["OATMEAL_REAL_WHISPER_MODEL"]
        else { throw XCTSkip("Set a real Whisper model path to run local inference.") }
        let audio = try realFixtureAudio()
        let engine = try WhisperServerEngine.bundled(modelURL: URL(fileURLWithPath: modelPath))
        addTeardownBlock { engine.shutdown() }

        let transcript = try await engine.transcribe(.init(
            source: .system,
            startMS: 0,
            sampleRate: 16_000,
            channels: 1,
            samples: audio
        ))

        XCTAssertTrue(transcript.lowercased().contains("fellow americans"))
    }

    func testRealWhisperServerLatencyWhenConfigured() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["OATMEAL_REAL_WHISPER_LATENCY_MODEL"]
        else { throw XCTSkip("Set a real curated Whisper model path to measure warm-runtime latency.") }
        let audio = try realFixtureAudio()
        let engine = try WhisperServerEngine.bundled(modelURL: URL(fileURLWithPath: modelPath))
        addTeardownBlock { engine.shutdown() }
        try await engine.validateModel()

        let firstWindowStart = Date()
        _ = try await engine.transcribe(.init(source: .microphone, startMS: 0, sampleRate: 16_000, channels: 1, samples: audio), partial: { _ in })
        XCTAssertLessThan(Date().timeIntervalSince(firstWindowStart), 5)

        let concurrentStart = Date()
        async let microphone: String = engine.transcribe(
            .init(source: .microphone, startMS: 5_000, sampleRate: 16_000, channels: 1, samples: audio),
            partial: { _ in }
        )
        async let system: String = engine.transcribe(
            .init(source: .system, startMS: 5_000, sampleRate: 16_000, channels: 1, samples: audio),
            partial: { _ in }
        )
        _ = try await (microphone, system)
        XCTAssertLessThan(Date().timeIntervalSince(concurrentStart), 5)
    }

    private func realFixtureAudio() throws -> [Float] {
        guard let audioPath = ProcessInfo.processInfo.environment["OATMEAL_REAL_WHISPER_AUDIO"]
        else { throw XCTSkip("Set a real Whisper audio fixture path to run local inference.") }
        let audio = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        return stride(from: 44, to: audio.count - 1, by: 2).map { index in
            Float(Int16(bitPattern: UInt16(audio[index]) | UInt16(audio[index + 1]) << 8)) / 32_768
        }
    }

    private func modelFile() throws -> URL {
        let directory = try temporaryDirectory()
        let model = directory.appendingPathComponent("model.bin")
        var modelData = Data("lmgg".utf8)
        modelData.append(Data(count: 1_000_000))
        try modelData.write(to: model)
        return model
    }

    private func databaseURL() throws -> URL {
        try temporaryDirectory().appendingPathComponent("oatmeal.sqlite")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private extension CapturedAudioChunk {
    static func fixture(source: AudioSource, startMS: Int64) -> Self {
        .init(source: source, startMS: startMS, sampleRate: 16_000, channels: 1, samples: [0.1])
    }
}

private enum FixtureError: Error { case failed }

private actor FixtureTranscriptionEngine: TranscriptionEngine {
    let results: [Int64: Result<String, Error>]
    let partials: [Int64: String]
    let delays: [Int64: UInt64]
    private(set) var callCount = 0

    init(results: [Int64: Result<String, Error>], partials: [Int64: String] = [:], delays: [Int64: UInt64] = [:]) {
        self.results = results
        self.partials = partials
        self.delays = delays
    }

    func validateModel() async throws {}

    func transcribe(_ chunk: CapturedAudioChunk, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        callCount += 1
        if let text = partials[chunk.startMS] { partial(text) }
        if let delay = delays[chunk.startMS] { try await Task.sleep(nanoseconds: delay) }
        return try results[chunk.startMS]!.get()
    }
}

private actor StringCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class FakeWhisperRuntimeLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var launchList: [AudioSource] = []
    private var runtimeMap: [AudioSource: FakeWhisperRuntime] = [:]
    private var readyError: Error?
    private var readyDelayNanoseconds: UInt64 = 0

    var launches: [AudioSource] { lock.withLock { launchList } }
    var launchCount: Int { lock.withLock { launchList.count } }
    var runtimes: [AudioSource: FakeWhisperRuntime] { lock.withLock { runtimeMap } }

    func setReadyError(_ error: Error?) { lock.withLock { readyError = error } }
    func setReadyDelay(nanoseconds: UInt64) { lock.withLock { readyDelayNanoseconds = nanoseconds } }

    func launch(_ source: AudioSource, _ modelURL: URL) throws -> any WhisperRuntimeProcess {
        let error = lock.withLock { readyError }
        let delay = lock.withLock { readyDelayNanoseconds }
        let runtime = FakeWhisperRuntime(source: source, readyError: error, readyDelayNanoseconds: delay)
        lock.withLock {
            launchList.append(source)
            runtimeMap[source] = runtime
        }
        return runtime
    }
}

private final class FakeWhisperRuntime: WhisperRuntimeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminatedFlag = false
    private var inferCallCount = 0
    private let source: AudioSource
    private let readyError: Error?
    private let readyDelayNanoseconds: UInt64

    init(source: AudioSource, readyError: Error?, readyDelayNanoseconds: UInt64 = 0) {
        self.source = source
        self.readyError = readyError
        self.readyDelayNanoseconds = readyDelayNanoseconds
    }

    var isRunning: Bool { lock.withLock { running } }
    var terminated: Bool { lock.withLock { terminatedFlag } }

    func waitUntilReady(timeout: TimeInterval) async throws {
        if readyDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: readyDelayNanoseconds) }
        if let readyError {
            lock.withLock { running = false }
            throw readyError
        }
    }

    func infer(wav: Data) async throws -> String {
        try await Task.sleep(nanoseconds: 200_000_000)
        try Task.checkCancellation()
        let index = lock.withLock { () -> Int in
            inferCallCount += 1
            return inferCallCount
        }
        return "\(source.rawValue)-\(index)"
    }

    func terminate() {
        lock.withLock {
            running = false
            terminatedFlag = true
        }
    }
}
