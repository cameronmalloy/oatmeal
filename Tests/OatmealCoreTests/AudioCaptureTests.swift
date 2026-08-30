import XCTest
@testable import OatmealCore

final class AudioCaptureTests: XCTestCase {
    func testBufferKeepsSourceAndDropsOldestChunkAtCapacity() async {
        let buffer = BoundedAudioBuffer(capacity: 2)
        await buffer.append(.fixture(source: .microphone, startMS: 1))
        await buffer.append(.fixture(source: .system, startMS: 2))
        await buffer.append(.fixture(source: .microphone, startMS: 3))

        let chunks = await buffer.drain()
        let dropped = await buffer.droppedCount
        XCTAssertEqual(chunks.map(\.startMS), [2, 3])
        XCTAssertEqual(chunks.map(\.source), [.system, .microphone])
        XCTAssertEqual(dropped, 1)
    }

    func testChunkDurationUsesSampleCountAndChannelCount() {
        let chunk = CapturedAudioChunk(
            source: .microphone,
            startMS: 0,
            sampleRate: 16_000,
            channels: 1,
            samples: Array(repeating: 0, count: 8_000)
        )

        XCTAssertEqual(chunk.durationMS, 500)
    }

    func testSpeechSamplesAreNormalizedToSixteenKilohertz() {
        let normalized = AudioSamples.resample([0, 0.25, 0.5, 0.75], from: 4, to: 2)

        XCTAssertEqual(normalized, [0, 0.5])
    }

    func testDualCapturePreservesBothLogicalSources() async throws {
        let microphone = FixtureCapture(chunk: .fixture(source: .microphone, startMS: 1))
        let system = FixtureCapture(chunk: .fixture(source: .system, startMS: 2))
        let coordinator = DualCaptureCoordinator(microphone: microphone, system: system)
        let collector = ChunkCollector()

        try await coordinator.start { chunk in Task { await collector.append(chunk) } }
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.stop()

        let sources = await collector.sources
        XCTAssertEqual(Set(sources), Set([.microphone, .system]))
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.stopCount, 1)
    }

    func testDualCaptureStopsMicrophoneWhenSystemStartFails() async {
        let microphone = FixtureCapture(chunk: .fixture(source: .microphone, startMS: 1))
        let system = FixtureCapture(error: FixtureError.failed)
        let coordinator = DualCaptureCoordinator(microphone: microphone, system: system)

        do {
            try await coordinator.start { _ in }
            XCTFail("Expected capture start to fail")
        } catch {
            XCTAssertEqual(microphone.stopCount, 1)
        }
    }
}

private extension CapturedAudioChunk {
    static func fixture(source: AudioSource, startMS: Int64) -> Self {
        .init(source: source, startMS: startMS, sampleRate: 16_000, channels: 1, samples: [0])
    }
}

private actor ChunkCollector {
    private var chunks: [CapturedAudioChunk] = []
    func append(_ chunk: CapturedAudioChunk) { chunks.append(chunk) }
    var sources: [AudioSource] { chunks.map(\.source) }
}

private enum FixtureError: Error { case failed }

private final class FixtureCapture: AudioCaptureSource, @unchecked Sendable {
    private let chunk: CapturedAudioChunk?
    private let error: Error?
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    init(chunk: CapturedAudioChunk? = nil, error: Error? = nil) {
        self.chunk = chunk
        self.error = error
    }

    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        if let error { throw error }
        if let chunk { handler(chunk) }
    }

    func stop() async { lock.withLock { stops += 1 } }
}
