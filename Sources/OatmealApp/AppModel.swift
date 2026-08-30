import AppKit
import Combine
import Foundation
import OatmealCore

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: UUID?
    @Published var selectedMeeting: Meeting?
    @Published var workflowStatus: MeetingStatus = .idle
    @Published var partialTranscript: [AudioSource: String] = [:]
    @Published var visibleError: String?
    @Published var noteDraft = ""
    @Published var downloadProgress = 0.0
    @Published var downloadingModelID: String?
    @Published var modelSetupKind: ModelKind?

    private let store: MeetingStore
    private var workflow: MeetingWorkflow?
    private var downloadTask: Task<Void, Never>?

    init() {
        do {
            let url: URL
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                url = FileManager.default.temporaryDirectory.appendingPathComponent("oatmeal-ui-\(UUID().uuidString).sqlite")
            } else {
                url = try MeetingStore.applicationDatabaseURL()
            }
            store = try MeetingStore(url: url)
            configureWorkflow()
            Task {
                try? await workflow?.recoverInterruptedMeetings()
                reloadHistory()
            }
        } catch {
            fatalError("Oatmeal could not open its local database: \(error.localizedDescription)")
        }
    }

    var configuration: ModelConfiguration { (try? store.modelConfiguration()) ?? .init() }
    var hasTranscriptionModel: Bool { configuration.transcriptionModelPath != nil }
    var hasGenerationModel: Bool { configuration.generationModelPath != nil }

    func reloadHistory(select id: UUID? = nil) {
        do {
            meetings = try store.meetings()
            if let id { selectedMeetingID = id }
            if let selectedMeetingID { selectedMeeting = try store.meeting(id: selectedMeetingID) }
            else if let first = meetings.first { selectMeeting(first.id) }
        } catch { visibleError = error.localizedDescription }
    }

    func selectMeeting(_ id: UUID?) {
        selectedMeetingID = id
        selectedMeeting = id.flatMap { try? store.meeting(id: $0) }
    }

    func startMeeting() {
        guard let workflow else {
            modelSetupKind = .transcription
            visibleError = "Download and select a transcription model first."
            return
        }
        Task {
            do {
                let id = try await workflow.start()
                selectedMeetingID = id
                await refreshWorkflow()
                reloadHistory(select: id)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func stopMeeting() {
        Task {
            do {
                try await workflow?.stop()
                await refreshWorkflow()
                reloadHistory(select: selectedMeetingID)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func saveDraftNote() {
        let draft = noteDraft
        Task {
            do {
                _ = try await workflow?.addUserNote(draft)
                noteDraft = ""
                reloadHistory(select: selectedMeetingID)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func updateUserNote(_ note: UserNote, text: String) {
        var note = note
        note.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.text.isEmpty else { return }
        note.updatedAt = Date()
        Task {
            do {
                try await workflow?.saveUserNote(note)
                reloadHistory(select: selectedMeetingID)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func generateNotes() {
        guard hasGenerationModel else {
            modelSetupKind = .generation
            return
        }
        guard let meetingID = selectedMeetingID else { return }
        Task {
            do {
                _ = try await workflow?.generateNotes(meetingID: meetingID)
                reloadHistory(select: meetingID)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func renameSelected(to title: String) {
        guard let id = selectedMeetingID else { return }
        Task {
            do {
                try await workflow?.renameMeeting(id: id, title: title)
                reloadHistory(select: id)
            } catch { visibleError = error.localizedDescription }
        }
    }

    func deleteSelected() {
        guard let id = selectedMeetingID else { return }
        Task {
            do {
                try await workflow?.deleteMeeting(id: id)
                selectedMeetingID = nil
                selectedMeeting = nil
                reloadHistory()
            } catch { visibleError = error.localizedDescription }
        }
    }

    func download(_ descriptor: ModelDescriptor) {
        downloadTask?.cancel()
        downloadingModelID = descriptor.id
        downloadProgress = 0
        downloadTask = Task {
            do {
                let destination = try ModelStorage.url(for: descriptor)
                _ = try await ModelDownloader().download(descriptor, to: destination) { [weak self] progress in
                    let model = self
                    Task { @MainActor in model?.downloadProgress = progress }
                }
                var configuration = try store.modelConfiguration()
                switch descriptor.kind {
                case .transcription:
                    configuration.transcriptionModelID = descriptor.id
                    configuration.transcriptionModelPath = destination.path
                case .generation:
                    configuration.generationModelID = descriptor.id
                    configuration.generationModelPath = destination.path
                }
                try store.saveModelConfiguration(configuration)
                downloadingModelID = nil
                downloadProgress = 1
                modelSetupKind = nil
                configureWorkflow()
            } catch is CancellationError {
                downloadingModelID = nil
            } catch {
                downloadingModelID = nil
                visibleError = error.localizedDescription
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelID = nil
    }

    func openModelsFolder() {
        do { NSWorkspace.shared.open(try ModelStorage.directory()) }
        catch { visibleError = error.localizedDescription }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func configureWorkflow() {
        guard
            let transcriptionPath = configuration.transcriptionModelPath,
            let whisper = try? WhisperProcessEngine.bundled(modelURL: URL(fileURLWithPath: transcriptionPath))
        else {
            workflow = nil
            return
        }
        let clock = CaptureClock()
        let capture = DualCaptureCoordinator(
            microphone: MicrophoneCapture(clock: clock),
            system: SystemAudioCapture(clock: clock)
        )
        let transcriber = TranscriptionCoordinator(engine: whisper, store: store)
        var generator: NoteGenerationService?
        if
            let generationPath = configuration.generationModelPath,
            let modelID = configuration.generationModelID,
            let llama = try? LlamaProcessEngine.bundled(modelURL: URL(fileURLWithPath: generationPath))
        {
            generator = NoteGenerationService(engine: llama, store: store, modelIdentifier: modelID)
        }
        workflow = MeetingWorkflow(
            store: store,
            capture: capture,
            transcriber: transcriber,
            generator: generator,
            permissions: { await CapturePermissions.request() },
            clock: clock,
            onUpdate: { [weak self] in
                let model = self
                Task { @MainActor in await model?.refreshWorkflow() }
            }
        )
    }

    private func refreshWorkflow() async {
        guard let snapshot = await workflow?.snapshot() else { return }
        workflowStatus = snapshot.status
        partialTranscript = snapshot.partialTranscript
        if let error = snapshot.visibleError { visibleError = error }
        reloadHistory(select: snapshot.activeMeetingID ?? selectedMeetingID)
    }
}
