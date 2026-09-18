import XCTest
@testable import OatmealCore

final class MeetingWorkflowTests: XCTestCase {
    func testIngressBufferBoundsEachSourceByAudioDuration() {
        let ingress = DurationBoundedAudioIngress(maximumAudioMSPerSource: 3)
        for millisecond in 0..<10 {
            ingress.append(.init(source: .microphone, startMS: Int64(millisecond), sampleRate: 1_000, channels: 1, samples: [0.1]))
        }
        ingress.append(.init(source: .system, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1, 0.1, 0.1]))

        let drained = ingress.drain()

        XCTAssertEqual(drained.chunks.filter { $0.source == .microphone }.reduce(0) { $0 + $1.durationMS }, 3)
        XCTAssertEqual(drained.chunks.filter { $0.source == .system }.reduce(0) { $0 + $1.durationMS }, 3)
        XCTAssertEqual(drained.droppedCount, 7)
    }

    func testOfflineWorkflowPersistsTranscriptNotesAndGeneratedMarkdown() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = FixtureMeetingCapture(chunks: [
            .init(source: .microphone, startMS: 1, sampleRate: 16_000, channels: 1, samples: [0]),
            .init(source: .system, startMS: 2, sampleRate: 16_000, channels: 1, samples: [0]),
        ])
        let transcriber = FixtureMeetingTranscriber(store: store)
        let generator = FixtureMeetingGenerator(store: store)
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: generator,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 1, maximumSamplesPerSource: 4)
        )

        let meetingID = try await workflow.start(title: "Standup")
        _ = try await workflow.addUserNote("Important")
        try await workflow.stop()
        _ = try await workflow.generateNotes(meetingID: meetingID)

        let reopened = try store.meeting(id: meetingID)
        XCTAssertEqual(reopened?.status, .completed)
        XCTAssertEqual(reopened?.transcript.map(\.source), [.me, .others])
        XCTAssertEqual(reopened?.userNotes.map(\.text), ["Important"])
        XCTAssertNotNil(reopened?.latestGeneratedNote)
    }

    func testMissingPermissionPreventsMeetingCreation() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let workflow = MeetingWorkflow(
            store: store,
            capture: FixtureMeetingCapture(),
            transcriber: FixtureMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .denied, systemAudio: .granted) }
        )

        do {
            _ = try await workflow.start()
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(try store.meetings(), [])
        }
    }

    func testPermissionFailuresNameTheCorrectSystemSettingsPane() {
        let microphone = MeetingWorkflow.WorkflowError.permissionsRequired(.init(microphone: .denied, systemAudio: .granted))
        let systemAudio = MeetingWorkflow.WorkflowError.permissionsRequired(.init(microphone: .granted, systemAudio: .denied))

        XCTAssertTrue(microphone.localizedDescription.contains("Microphone"))
        XCTAssertTrue(systemAudio.localizedDescription.contains("Screen Recording"))
    }

    func testCaptureFailureLeavesRecoverableMeetingRecord() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let workflow = MeetingWorkflow(
            store: store,
            capture: FixtureMeetingCapture(error: FixtureWorkflowError.failed),
            transcriber: FixtureMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) }
        )

        do {
            _ = try await workflow.start()
            XCTFail("Expected capture failure")
        } catch {
            XCTAssertEqual(try store.meetings().count, 1)
            XCTAssertEqual(try store.meetings().first?.status, .failed)
        }
    }

    func testCaptureFailureDiscardsPendingAudioBeforeRetry() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = RetryMeetingCapture()
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: FixtureMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 2, maximumSamplesPerSource: 10)
        )

        do {
            _ = try await workflow.start()
            XCTFail("Expected first capture start to fail")
        } catch {
            let failed = await workflow.snapshot()
            XCTAssertNil(failed.activeMeetingID)
        }
        let meetingID = try await workflow.start()
        try await workflow.stop()

        XCTAssertEqual(try store.meeting(id: meetingID)?.transcript.map(\.startMS), [100])
    }

    func testSilenceWithinSpeechWindowPreservesAudioDuration() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = FixtureMeetingCapture(chunks: [
            .init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]),
            .init(source: .microphone, startMS: 1, sampleRate: 1_000, channels: 1, samples: Array(repeating: 0, count: 98)),
            .init(source: .microphone, startMS: 99, sampleRate: 1_000, channels: 1, samples: [0.1]),
        ])
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: ActivityMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 100, maximumSamplesPerSource: 200)
        )

        let meetingID = try await workflow.start()
        try await workflow.stop()

        XCTAssertEqual(try store.meeting(id: meetingID)?.transcript.map(\.endMS), [100])
    }

    func testDelayedPartialFromFailedStartDoesNotEnterRetry() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let workflow = MeetingWorkflow(
            store: store,
            capture: PartialRetryMeetingCapture(),
            transcriber: DelayedPartialMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 1, maximumSamplesPerSource: 10)
        )

        do { _ = try await workflow.start() } catch {}
        _ = try await workflow.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let retried = await workflow.snapshot()

        XCTAssertEqual(retried.partialTranscript, [:])
        try await workflow.stop()
    }

    func testRelaunchMarksInterruptedMeetingFailedWithoutDeletingText() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(status: .capturing)
        try store.saveMeeting(meeting)
        try store.saveSegment(.init(meetingID: meeting.id, source: .me, startMS: 1, endMS: 2, text: "Durable"))
        let workflow = MeetingWorkflow(
            store: store,
            capture: FixtureMeetingCapture(),
            transcriber: FixtureMeetingTranscriber(store: store),
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) }
        )

        try await workflow.recoverInterruptedMeetings()

        XCTAssertEqual(try store.meeting(id: meeting.id)?.status, .failed)
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript.map(\.text), ["Durable"])
    }

    func testCallbackGranularityDoesNotDropEqualDurationAudioWhileInferenceIsDelayed() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = ControllableMeetingCapture()
        let transcriber = DelayedMeetingTranscriber(store: store)
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 1, maximumSamplesPerSource: 1_000)
        )
        let meetingID = try await workflow.start()

        await capture.send(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]))
        await transcriber.waitUntilStarted()
        for millisecond in 1..<128 {
            await capture.send(.init(source: .microphone, startMS: Int64(millisecond), sampleRate: 1_000, channels: 1, samples: [0.1]))
        }
        await capture.send(.init(source: .system, startMS: 0, sampleRate: 1_000, channels: 1, samples: Array(repeating: 0.1, count: 128)))
        for _ in 0..<100 { await Task.yield() }
        let pressured = await workflow.snapshot()

        await transcriber.release()
        try await workflow.stop()
        let received = await transcriber.received
        XCTAssertEqual(pressured.droppedAudioChunks, 0)
        XCTAssertEqual(received.filter { $0.source == .microphone }.reduce(0) { $0 + $1.samples.count }, 128)
        XCTAssertEqual(received.filter { $0.source == .system }.reduce(0) { $0 + $1.samples.count }, 128)
        XCTAssertEqual(received.filter { $0.source == .microphone }.map(\.startMS), received.filter { $0.source == .microphone }.map(\.startMS).sorted())
        XCTAssertEqual(received.filter { $0.source == .system }.map(\.startMS), received.filter { $0.source == .system }.map(\.startMS).sorted())
        XCTAssertEqual(try store.meeting(id: meetingID)?.transcript.map(\.startMS), try store.meeting(id: meetingID)?.transcript.map(\.startMS).sorted())
    }

    func testInFlightAudioCountsTowardDurationCapacity() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = ControllableMeetingCapture()
        let transcriber = DelayedMeetingTranscriber(store: store)
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 2, maximumSamplesPerSource: 10),
            maximumQueuedAudioMSPerSource: 3
        )
        try await workflow.start()

        await capture.send(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1, 0.1]))
        await transcriber.waitUntilStarted()
        await capture.send(.init(source: .microphone, startMS: 2, sampleRate: 1_000, channels: 1, samples: [0.1, 0.1]))
        for _ in 0..<100 { await Task.yield() }

        let pressured = await workflow.snapshot()
        XCTAssertEqual(pressured.droppedAudioChunks, 1)
        await transcriber.release()
        try await workflow.stop()
        let received = await transcriber.received
        XCTAssertEqual(received.count, 1)
    }

    func testRepeatedStopWhileDrainingIsIdempotent() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = ControllableMeetingCapture()
        let transcriber = DelayedMeetingTranscriber(store: store)
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 1, maximumSamplesPerSource: 10)
        )
        try await workflow.start()
        await capture.send(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]))
        await transcriber.waitUntilStarted()

        let firstStop = Task { try await workflow.stop() }
        for _ in 0..<1_000 {
            if await workflow.snapshot().status == .stopping { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        try await workflow.stop()
        await transcriber.release()
        try await firstStop.value

        let completed = await workflow.snapshot()
        XCTAssertEqual(completed.status, .completed)
    }

    func testOverloadIsOneRecoverableEpisodeAndCanRecur() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let capture = ControllableMeetingCapture()
        let transcriber = DelayedMeetingTranscriber(store: store)
        let workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: nil,
            permissions: { .init(microphone: .granted, systemAudio: .granted) },
            windowAssembler: .init(windowSamples: 1, maximumSamplesPerSource: 1_000),
            maximumQueuedAudioMSPerSource: 3
        )
        let meetingID = try await workflow.start()
        await transcriber.release()
        await capture.send(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]))
        for _ in 0..<1_000 {
            if try store.meeting(id: meetingID)?.transcript.count == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await transcriber.pause()
        await capture.send(.init(source: .microphone, startMS: 1, sampleRate: 1_000, channels: 1, samples: [0.1]))
        await transcriber.waitUntilReceived(2)
        for millisecond in 2..<12 {
            await capture.send(.init(source: .microphone, startMS: Int64(millisecond), sampleRate: 1_000, channels: 1, samples: [0.1]))
        }
        for _ in 0..<1_000 {
            if await workflow.snapshot().droppedAudioChunks > 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let firstEpisode = await workflow.snapshot()

        await transcriber.release()
        for _ in 0..<1_000 {
            if await workflow.snapshot().status == .capturing { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let recovered = await workflow.snapshot()
        await transcriber.pause()
        let receivedBeforeSecondEpisode = await transcriber.received.count
        await capture.send(.init(source: .system, startMS: 20, sampleRate: 1_000, channels: 1, samples: [0.1]))
        await transcriber.waitUntilReceived(receivedBeforeSecondEpisode + 1)
        for millisecond in 21..<31 {
            await capture.send(.init(source: .system, startMS: Int64(millisecond), sampleRate: 1_000, channels: 1, samples: [0.1]))
        }
        for _ in 0..<1_000 {
            let snapshot = await workflow.snapshot()
            if snapshot.droppedAudioChunks > firstEpisode.droppedAudioChunks, snapshot.status == .degraded { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let secondEpisode = await workflow.snapshot()

        await transcriber.release()
        try await workflow.stop()
        XCTAssertGreaterThan(firstEpisode.droppedAudioChunks, 1)
        XCTAssertEqual(firstEpisode.status, .degraded)
        XCTAssertNil(firstEpisode.visibleError)
        XCTAssertNotNil(firstEpisode.backlogStatus)
        XCTAssertEqual(try store.meeting(id: meetingID)?.transcript.first?.text, "microphone-0")
        XCTAssertEqual(recovered.status, .capturing)
        XCTAssertNil(recovered.visibleError)
        XCTAssertNil(recovered.backlogStatus)
        XCTAssertEqual(secondEpisode.status, .degraded)
        XCTAssertNotNil(secondEpisode.backlogStatus)
        XCTAssertGreaterThan(secondEpisode.droppedAudioChunks, firstEpisode.droppedAudioChunks)
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("oatmeal.sqlite")
    }
}

private enum FixtureWorkflowError: Error { case failed }

private actor FixtureMeetingCapture: MeetingCapturing {
    private let chunks: [CapturedAudioChunk]
    private let error: Error?
    init(chunks: [CapturedAudioChunk] = [], error: Error? = nil) { self.chunks = chunks; self.error = error }
    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        if let error { throw error }
        chunks.forEach(handler)
    }
    func stop() async {}
}

private actor ControllableMeetingCapture: MeetingCapturing {
    private var handler: (@Sendable (CapturedAudioChunk) -> Void)?
    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws { self.handler = handler }
    func stop() async { handler = nil }
    func send(_ chunk: CapturedAudioChunk) { handler?(chunk) }
}

private actor RetryMeetingCapture: MeetingCapturing {
    private var attempt = 0

    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        attempt += 1
        if attempt == 1 {
            handler(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]))
            throw FixtureWorkflowError.failed
        }
        handler(.init(source: .microphone, startMS: 100, sampleRate: 1_000, channels: 1, samples: [0.1]))
    }

    func stop() async {}
}

private actor PartialRetryMeetingCapture: MeetingCapturing {
    private var attempt = 0

    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        attempt += 1
        if attempt == 1 {
            handler(.init(source: .microphone, startMS: 0, sampleRate: 1_000, channels: 1, samples: [0.1]))
            throw FixtureWorkflowError.failed
        }
    }

    func stop() async {}
}

private actor FixtureMeetingTranscriber: MeetingTranscribing {
    private let store: MeetingStore
    init(store: MeetingStore) { self.store = store }
    func validateModel() async throws {}
    func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID, partial: @escaping @Sendable (String) -> Void) async throws -> TranscriptSegment? {
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: TranscriptSource(chunk.source),
            startMS: chunk.startMS,
            endMS: chunk.startMS + chunk.durationMS,
            text: chunk.source == .microphone ? "Me speaking" : "Others speaking"
        )
        try store.saveSegment(segment)
        return segment
    }
}

private actor ActivityMeetingTranscriber: MeetingTranscribing {
    private let store: MeetingStore
    init(store: MeetingStore) { self.store = store }
    func validateModel() async throws {}
    nonisolated func hasActivity(_ chunk: CapturedAudioChunk) -> Bool { chunk.samples.contains { abs($0) > 0.01 } }
    func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID, partial: @escaping @Sendable (String) -> Void) async throws -> TranscriptSegment? {
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: TranscriptSource(chunk.source),
            startMS: chunk.startMS,
            endMS: chunk.startMS + chunk.durationMS,
            text: "Speech"
        )
        try store.saveSegment(segment)
        return segment
    }
}

private actor DelayedPartialMeetingTranscriber: MeetingTranscribing {
    private let store: MeetingStore
    init(store: MeetingStore) { self.store = store }
    func validateModel() async throws {}
    func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID, partial: @escaping @Sendable (String) -> Void) async throws -> TranscriptSegment? {
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            partial("Stale")
        }
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: TranscriptSource(chunk.source),
            startMS: chunk.startMS,
            endMS: chunk.startMS + chunk.durationMS,
            text: "Old"
        )
        try store.saveSegment(segment)
        return segment
    }
}

private actor DelayedMeetingTranscriber: MeetingTranscribing {
    private let store: MeetingStore
    private var released = false
    private var receivedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var received: [CapturedAudioChunk] = []

    init(store: MeetingStore) { self.store = store }
    func validateModel() async throws {}

    func waitUntilStarted() async {
        await waitUntilReceived(1)
    }

    func waitUntilReceived(_ count: Int) async {
        if received.count >= count { return }
        await withCheckedContinuation { receivedWaiters.append((count, $0)) }
    }

    func pause() {
        released = false
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID, partial: @escaping @Sendable (String) -> Void) async throws -> TranscriptSegment? {
        received.append(chunk)
        let ready = receivedWaiters.filter { received.count >= $0.0 }
        receivedWaiters.removeAll { received.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: TranscriptSource(chunk.source),
            startMS: chunk.startMS,
            endMS: chunk.startMS + chunk.durationMS,
            text: "\(chunk.source.rawValue)-\(chunk.startMS)"
        )
        try store.saveSegment(segment)
        return segment
    }
}

private actor FixtureMeetingGenerator: MeetingNoteGenerating {
    private let store: MeetingStore
    init(store: MeetingStore) { self.store = store }
    func generate(meetingID: UUID) async throws -> GeneratedNote {
        let note = GeneratedNote(
            meetingID: meetingID,
            modelIdentifier: "fixture",
            promptVersion: "v1",
            content: "# Summary\nS\n# Decisions\nNone\n# Action Items\nNone\n# Open Questions\nNone\n# Important Context\nNone"
        )
        try store.saveGeneratedNote(note)
        return note
    }
}
