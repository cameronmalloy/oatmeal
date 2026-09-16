import Foundation

public protocol MeetingCapturing: Sendable {
    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws
    func stop() async
}

extension DualCaptureCoordinator: MeetingCapturing {}

public protocol MeetingTranscribing: Sendable {
    func validateModel() async throws
    func hasActivity(_ chunk: CapturedAudioChunk) -> Bool
    func transcribe(
        _ chunk: CapturedAudioChunk,
        meetingID: UUID,
        partial: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptSegment?
}

public extension MeetingTranscribing {
    func hasActivity(_ chunk: CapturedAudioChunk) -> Bool { true }
}

extension TranscriptionCoordinator: MeetingTranscribing {}

public protocol MeetingNoteGenerating: Sendable {
    func generate(meetingID: UUID) async throws -> GeneratedNote
}

extension NoteGenerationService: MeetingNoteGenerating {}

final class DurationBoundedAudioIngress: @unchecked Sendable {
    struct Drain {
        let chunks: [CapturedAudioChunk]
        let droppedCount: Int
    }

    private let maximumAudioMSPerSource: Int64
    private let lock = NSLock()
    private var chunks: [CapturedAudioChunk] = []
    private var durationMS: [AudioSource: Int64] = [:]
    private var droppedCount = 0

    init(maximumAudioMSPerSource: Int64) {
        self.maximumAudioMSPerSource = max(1, maximumAudioMSPerSource)
    }

    func append(_ chunk: CapturedAudioChunk) {
        lock.withLock {
            let incomingDuration = max(1, chunk.durationMS)
            var sourceDuration = durationMS[chunk.source, default: 0]
            while sourceDuration + incomingDuration > maximumAudioMSPerSource,
                  let index = chunks.firstIndex(where: { $0.source == chunk.source }) {
                sourceDuration -= max(1, chunks.remove(at: index).durationMS)
                droppedCount += 1
            }
            guard sourceDuration + incomingDuration <= maximumAudioMSPerSource else {
                droppedCount += 1
                return
            }
            chunks.append(chunk)
            durationMS[chunk.source] = sourceDuration + incomingDuration
        }
    }

    func drain() -> Drain {
        lock.withLock {
            defer {
                chunks.removeAll(keepingCapacity: true)
                durationMS.removeAll(keepingCapacity: true)
                droppedCount = 0
            }
            return Drain(chunks: chunks, droppedCount: droppedCount)
        }
    }
}

public struct MeetingWorkflowSnapshot: Equatable, Sendable {
    public let status: MeetingStatus
    public let activeMeetingID: UUID?
    public let partialTranscript: [AudioSource: String]
    public let visibleError: String?
    public let droppedAudioChunks: Int

    public var backlogStatus: String? {
        guard status == .degraded, visibleError == nil, droppedAudioChunks > 0 else { return nil }
        return "Transcription is behind; \(droppedAudioChunks) unprocessed audio chunk\(droppedAudioChunks == 1 ? " was" : "s were") dropped."
    }
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
    private let maximumQueuedAudioMSPerSource: Int64
    private let clock: CaptureClock
    private let onUpdate: @Sendable () -> Void
    private var lifecycle = MeetingLifecycle()
    private var continuation: AsyncStream<Void>.Continuation?
    private var processor: Task<Void, Never>?
    private var workers: [AudioSource: Task<Void, Never>] = [:]
    private var queuedWindows: [AudioSource: [CapturedAudioChunk]] = [:]
    private var queuedAudioMS: [AudioSource: Int64] = [:]
    private var activeMeetingID: UUID?
    private var partialTranscript: [AudioSource: String] = [:]
    private var visibleError: String?
    private var droppedAudioChunks = 0
    private var overloadActive = false

    public init(
        store: MeetingStore,
        capture: any MeetingCapturing,
        transcriber: any MeetingTranscribing,
        generator: (any MeetingNoteGenerating)?,
        permissions: @escaping @Sendable () async -> CapturePermissionStatus,
        windowAssembler: AudioWindowAssembler = .init(),
        maximumQueuedAudioMSPerSource: Int64 = 60_000,
        clock: CaptureClock = .init(),
        onUpdate: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.capture = capture
        self.transcriber = transcriber
        self.generator = generator
        self.permissions = permissions
        self.windowAssembler = windowAssembler
        self.maximumQueuedAudioMSPerSource = max(1, maximumQueuedAudioMSPerSource)
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
        droppedAudioChunks = 0
        overloadActive = false
        queuedWindows.removeAll(keepingCapacity: true)
        queuedAudioMS.removeAll(keepingCapacity: true)

        let ingress = DurationBoundedAudioIngress(maximumAudioMSPerSource: maximumQueuedAudioMSPerSource)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        processor = Task { await consume(pair.stream, ingress: ingress, meetingID: meeting.id) }
        do {
            try await capture.start { chunk in
                ingress.append(chunk)
                pair.continuation.yield(())
            }
            try lifecycle.transition(to: .capturing)
            meeting.status = .capturing
            try store.saveMeeting(meeting)
            onUpdate()
            return meeting.id
        } catch {
            await capture.stop()
            pair.continuation.finish()
            _ = await processor?.value
            await windowAssembler.discard()
            await waitForWorkers()
            workers.removeAll(keepingCapacity: true)
            queuedWindows.removeAll(keepingCapacity: true)
            queuedAudioMS.removeAll(keepingCapacity: true)
            processor = nil
            continuation = nil
            activeMeetingID = nil
            partialTranscript.removeAll()
            overloadActive = false
            try? lifecycle.transition(to: .failed)
            meeting.status = .failed
            try? store.saveMeeting(meeting)
            visibleError = error.localizedDescription
            onUpdate()
            throw error
        }
    }

    public func stop() async throws {
        if lifecycle.status == .stopping { return }
        guard let meetingID = activeMeetingID, var meeting = try store.meeting(id: meetingID) else { throw WorkflowError.noActiveMeeting }
        try lifecycle.transition(to: .stopping)
        meeting.status = .stopping
        try store.saveMeeting(meeting)
        onUpdate()
        await capture.stop()
        continuation?.finish()
        _ = await processor?.value
        processor = nil
        continuation = nil
        for chunk in await windowAssembler.flush() where transcriber.hasActivity(chunk) {
            enqueue(chunk, meetingID: meetingID)
        }
        await waitForWorkers()
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

    private func consume(_ stream: AsyncStream<Void>, ingress: DurationBoundedAudioIngress, meetingID: UUID) async {
        for await _ in stream {
            await consume(ingress.drain(), meetingID: meetingID)
        }
        await consume(ingress.drain(), meetingID: meetingID)
    }

    private func consume(_ drain: DurationBoundedAudioIngress.Drain, meetingID: UUID) async {
        if drain.droppedCount > 0 { markBacklog(drain.droppedCount) }
        for chunk in drain.chunks {
            for window in await windowAssembler.append(chunk) where transcriber.hasActivity(window) {
                enqueue(window, meetingID: meetingID)
            }
        }
    }

    private func enqueue(_ chunk: CapturedAudioChunk, meetingID: UUID) {
        let duration = max(1, chunk.durationMS)
        var queue = queuedWindows[chunk.source, default: []]
        var queuedDuration = queuedAudioMS[chunk.source, default: 0]
        while queuedDuration + duration > maximumQueuedAudioMSPerSource, let dropped = queue.first {
            queue.removeFirst()
            queuedDuration -= max(1, dropped.durationMS)
            markBacklog()
        }
        guard queuedDuration + duration <= maximumQueuedAudioMSPerSource else {
            markBacklog()
            return
        }
        queue.append(chunk)
        queuedWindows[chunk.source] = queue
        queuedAudioMS[chunk.source] = queuedDuration + duration
        if workers[chunk.source] == nil {
            workers[chunk.source] = Task { await self.runWorker(source: chunk.source, meetingID: meetingID) }
        }
    }

    private func runWorker(source: AudioSource, meetingID: UUID) async {
        while let chunk = dequeue(source: source) {
            await transcribe(chunk, meetingID: meetingID)
            finish(chunk, meetingID: meetingID)
        }
        workers[source] = nil
    }

    private func dequeue(source: AudioSource) -> CapturedAudioChunk? {
        guard var queue = queuedWindows[source], !queue.isEmpty else { return nil }
        let chunk = queue.removeFirst()
        queuedWindows[source] = queue
        return chunk
    }

    private func finish(_ chunk: CapturedAudioChunk, meetingID: UUID) {
        queuedAudioMS[chunk.source, default: 0] -= max(1, chunk.durationMS)
        let recoveryThreshold = maximumQueuedAudioMSPerSource / 2
        guard overloadActive, AudioSource.allCases.allSatisfy({ queuedAudioMS[$0, default: 0] <= recoveryThreshold }) else { return }
        overloadActive = false
        guard visibleError == nil, lifecycle.status == .degraded else { return }
        try? lifecycle.transition(to: .capturing)
        if var meeting = try? store.meeting(id: meetingID) {
            meeting.status = .capturing
            try? store.saveMeeting(meeting)
        }
        onUpdate()
    }

    private func waitForWorkers() async {
        while !workers.isEmpty {
            for worker in Array(workers.values) { await worker.value }
        }
    }

    private func transcribe(_ chunk: CapturedAudioChunk, meetingID: UUID) async {
        do {
            _ = try await transcriber.transcribe(chunk, meetingID: meetingID) { [self] text in
                Task { await self.setPartial(text, source: chunk.source, meetingID: meetingID) }
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

    private func setPartial(_ text: String, source: AudioSource, meetingID: UUID) {
        guard activeMeetingID == meetingID else { return }
        partialTranscript[source] = text
        onUpdate()
    }

    private func markBacklog(_ count: Int = 1) {
        droppedAudioChunks += count
        guard !overloadActive else {
            onUpdate()
            return
        }
        overloadActive = true
        if lifecycle.status == .capturing { try? lifecycle.transition(to: .degraded) }
        if let activeMeetingID, var meeting = try? store.meeting(id: activeMeetingID) {
            meeting.status = .degraded
            try? store.saveMeeting(meeting)
        }
        onUpdate()
    }
}
