import Foundation

public protocol MeetingCapturing: Sendable {
    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws
    func stop() async
}

extension DualCaptureCoordinator: MeetingCapturing {}

public protocol MeetingTranscribing: Sendable {
    func validateModel() async throws
    func transcribe(
        _ chunk: CapturedAudioChunk,
        meetingID: UUID,
        partial: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptSegment
}

extension TranscriptionCoordinator: MeetingTranscribing {}

public protocol MeetingNoteGenerating: Sendable {
    func generate(meetingID: UUID) async throws -> GeneratedNote
}

extension NoteGenerationService: MeetingNoteGenerating {}

public struct MeetingWorkflowSnapshot: Equatable, Sendable {
    public let status: MeetingStatus
    public let activeMeetingID: UUID?
    public let partialTranscript: [AudioSource: String]
    public let visibleError: String?
    public let droppedAudioChunks: Int
}

public actor MeetingWorkflow {
    public enum WorkflowError: LocalizedError, Equatable {
        case permissionsRequired(CapturePermissionStatus)
        case noActiveMeeting
        case noteGenerationModelRequired
        case emptyNote

        public var errorDescription: String? {
            switch self {
            case let .permissionsRequired(status):
                if status.microphone != .granted { return "Microphone permission is required. Enable it in System Settings → Privacy & Security → Microphone." }
                return "Screen Recording permission is required for system audio. Enable it in System Settings → Privacy & Security → Screen Recording."
            case .noActiveMeeting: return "There is no active meeting."
            case .noteGenerationModelRequired: return "Download and select a local note-generation model first."
            case .emptyNote: return "A user note cannot be empty."
            }
        }
    }

    private let store: MeetingStore
    private let capture: any MeetingCapturing
    private let transcriber: any MeetingTranscribing
    private let generator: (any MeetingNoteGenerating)?
    private let permissions: @Sendable () async -> CapturePermissionStatus
    private let windowAssembler: AudioWindowAssembler
    private let clock: CaptureClock
    private let onUpdate: @Sendable () -> Void
    private var lifecycle = MeetingLifecycle()
    private var continuation: AsyncStream<CapturedAudioChunk>.Continuation?
    private var processor: Task<Void, Never>?
    private var activeMeetingID: UUID?
    private var partialTranscript: [AudioSource: String] = [:]
    private var visibleError: String?
    private var droppedAudioChunks = 0

    public init(
        store: MeetingStore,
        capture: any MeetingCapturing,
        transcriber: any MeetingTranscribing,
        generator: (any MeetingNoteGenerating)?,
        permissions: @escaping @Sendable () async -> CapturePermissionStatus,
        windowAssembler: AudioWindowAssembler = .init(),
        clock: CaptureClock = .init(),
        onUpdate: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.capture = capture
        self.transcriber = transcriber
        self.generator = generator
        self.permissions = permissions
        self.windowAssembler = windowAssembler
        self.clock = clock
        self.onUpdate = onUpdate
    }

    public func snapshot() -> MeetingWorkflowSnapshot {
        .init(
            status: lifecycle.status,
            activeMeetingID: activeMeetingID,
            partialTranscript: partialTranscript,
            visibleError: visibleError,
            droppedAudioChunks: droppedAudioChunks
        )
    }

    @discardableResult
    public func start(title: String = "New Meeting") async throws -> UUID {
        if lifecycle.status == .completed || lifecycle.status == .failed { lifecycle = MeetingLifecycle() }
        try lifecycle.transition(to: .starting)
        let permissionStatus = await permissions()
        guard permissionStatus.allGranted else {
            try? lifecycle.transition(to: .idle)
            throw WorkflowError.permissionsRequired(permissionStatus)
        }
        do { try await transcriber.validateModel() }
        catch {
            try? lifecycle.transition(to: .idle)
            throw error
        }

        var meeting = Meeting(title: title, startedAt: Date(), status: .starting)
        try store.saveMeeting(meeting)
        activeMeetingID = meeting.id
        visibleError = nil
        partialTranscript.removeAll()

        let pair = AsyncStream<CapturedAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(120))
        continuation = pair.continuation
        processor = Task { await consume(pair.stream, meetingID: meeting.id) }
        do {
            try await capture.start { [self] chunk in
                let result = pair.continuation.yield(chunk)
                if case .dropped = result { Task { await self.markBacklog() } }
            }
            try lifecycle.transition(to: .capturing)
            meeting.status = .capturing
            try store.saveMeeting(meeting)
            onUpdate()
            return meeting.id
        } catch {
            pair.continuation.finish()
            _ = await processor?.value
            try? lifecycle.transition(to: .failed)
            meeting.status = .failed
            try? store.saveMeeting(meeting)
            visibleError = error.localizedDescription
            onUpdate()
            throw error
        }
    }

    public func stop() async throws {
        guard let meetingID = activeMeetingID, var meeting = try store.meeting(id: meetingID) else { throw WorkflowError.noActiveMeeting }
        try lifecycle.transition(to: .stopping)
        meeting.status = .stopping
        try store.saveMeeting(meeting)
        await capture.stop()
        continuation?.finish()
        _ = await processor?.value
        processor = nil
        continuation = nil
        for chunk in await windowAssembler.flush() { await transcribe(chunk, meetingID: meetingID) }
        if lifecycle.status == .degraded { try lifecycle.transition(to: .stopping) }
        try lifecycle.transition(to: .finalizing)
        meeting.status = .finalizing
        try store.saveMeeting(meeting)
        try lifecycle.transition(to: .completed)
        meeting.status = .completed
        meeting.endedAt = Date()
        try store.saveMeeting(meeting)
        activeMeetingID = nil
        partialTranscript.removeAll()
        onUpdate()
    }

    @discardableResult
    public func addUserNote(_ text: String) throws -> UserNote {
        guard let meetingID = activeMeetingID else { throw WorkflowError.noActiveMeeting }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkflowError.emptyNote }
        let note = UserNote(meetingID: meetingID, meetingTimeMS: clock.nowMS, text: text)
        try store.saveUserNote(note)
        onUpdate()
        return note
    }

    public func saveUserNote(_ note: UserNote) throws {
        try store.saveUserNote(note)
        onUpdate()
    }

    @discardableResult
    public func generateNotes(meetingID: UUID) async throws -> GeneratedNote {
        guard let generator else { throw WorkflowError.noteGenerationModelRequired }
        let note = try await generator.generate(meetingID: meetingID)
        onUpdate()
        return note
    }

    public func renameMeeting(id: UUID, title: String) throws {
        try store.renameMeeting(id: id, title: title)
        onUpdate()
    }

    public func deleteMeeting(id: UUID) throws {
        try store.deleteMeeting(id: id)
        onUpdate()
    }

    public func recoverInterruptedMeetings() throws {
        for var meeting in try store.meetings() where [.starting, .capturing, .degraded, .stopping, .finalizing].contains(meeting.status) {
            meeting.status = .failed
            try store.saveMeeting(meeting)
        }
        onUpdate()
    }

    private func consume(_ stream: AsyncStream<CapturedAudioChunk>, meetingID: UUID) async {
        for await chunk in stream {
            for window in await windowAssembler.append(chunk) { await transcribe(window, meetingID: meetingID) }
        }
    }

    private func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID) async {
        do {
            _ = try await transcriber.transcribe(chunk, meetingID: meetingID) { [self] text in
                Task { await self.setPartial(text, source: chunk.source) }
            }
            partialTranscript[chunk.source] = nil
            onUpdate()
        } catch {
            visibleError = error.localizedDescription
            if lifecycle.status == .capturing { try? lifecycle.transition(to: .degraded) }
            if var meeting = try? store.meeting(id: meetingID) {
                meeting.status = .degraded
                try? store.saveMeeting(meeting)
            }
            onUpdate()
        }
    }

    private func setPartial(_ text: String, source: AudioSource) {
        partialTranscript[source] = text
        onUpdate()
    }

    private func markBacklog() {
        droppedAudioChunks += 1
        visibleError = "Transcription is behind; the oldest unprocessed audio chunk was dropped."
        if lifecycle.status == .capturing { try? lifecycle.transition(to: .degraded) }
        if let activeMeetingID, var meeting = try? store.meeting(id: activeMeetingID) {
            meeting.status = .degraded
            try? store.saveMeeting(meeting)
        }
        onUpdate()
    }
}
