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
            .init(source: .microphone, startMS: 1, sampleRate: 16_000, channels: 1, samples: [0]),
            meetingID: meeting.id,
            partial: { text in Task { await partials.append(text) } }
        )
        try await Task.sleep(nanoseconds: 10_000_000)

        let displayedPartials = await partials.values
        XCTAssertEqual(segment.source, .me)
        XCTAssertEqual(displayedPartials, ["hel"])
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["hello"])
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

    func testWhisperProcessDeletesTemporaryAudioAfterTranscription() async throws {
        let directory = try temporaryDirectory()
        let executable = directory.appendingPathComponent("whisper-cli")
        let script = "#!/bin/sh\ncase \" $* \" in *\" --no-gpu \"*) printf hello ;; *) exit 2 ;; esac\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("model.bin")
        var modelData = Data("lmgg".utf8)
        modelData.append(Data(count: 1_000_000))
        try modelData.write(to: model)
        let engine = WhisperProcessEngine(executableURL: executable, modelURL: model, temporaryDirectory: directory)

        let text = try await engine.transcribe(.fixture(source: .microphone, startMS: 0))

        XCTAssertEqual(text, "hello")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    func testRealWhisperFixtureWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["OATMEAL_REAL_WHISPER_MODEL"],
              let audioPath = environment["OATMEAL_REAL_WHISPER_AUDIO"]
        else { throw XCTSkip("Set real Whisper model and audio paths to run local inference.") }
        let audio = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let samples = stride(from: 44, to: audio.count - 1, by: 2).map { index in
            Float(Int16(bitPattern: UInt16(audio[index]) | UInt16(audio[index + 1]) << 8)) / 32_768
        }
        let engine = WhisperProcessEngine(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            modelURL: URL(fileURLWithPath: modelPath)
        )

        let transcript = try await engine.transcribe(.init(
            source: .system,
            startMS: 0,
            sampleRate: 16_000,
            channels: 1,
            samples: samples
        ))

        XCTAssertTrue(transcript.lowercased().contains("fellow americans"))
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
        .init(source: source, startMS: startMS, sampleRate: 16_000, channels: 1, samples: [0])
    }
}

private enum FixtureError: Error { case failed }

private actor FixtureTranscriptionEngine: TranscriptionEngine {
    let results: [Int64: Result<String, Error>]
    let partials: [Int64: String]
    let delays: [Int64: UInt64]

    init(results: [Int64: Result<String, Error>], partials: [Int64: String] = [:], delays: [Int64: UInt64] = [:]) {
        self.results = results
        self.partials = partials
        self.delays = delays
    }

    func validateModel() async throws {}

    func transcribe(_ chunk: CapturedAudioChunk, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        if let text = partials[chunk.startMS] { partial(text) }
        if let delay = delays[chunk.startMS] { try await Task.sleep(nanoseconds: delay) }
        return try results[chunk.startMS]!.get()
    }
}

private actor StringCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
