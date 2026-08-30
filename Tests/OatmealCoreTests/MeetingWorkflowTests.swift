import XCTest
@testable import OatmealCore

final class MeetingWorkflowTests: XCTestCase {
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

private actor FixtureMeetingTranscriber: MeetingTranscribing {
    private let store: MeetingStore
    init(store: MeetingStore) { self.store = store }
    func validateModel() async throws {}
    func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID, partial: @escaping @Sendable (String) -> Void) async throws -> TranscriptSegment {
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
