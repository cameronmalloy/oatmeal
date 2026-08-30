import Foundation

public enum PromptBuilder {
    public enum PromptError: LocalizedError {
        case noTranscript
        case contextTooSmall

        public var errorDescription: String? {
            switch self {
            case .noTranscript: "The meeting needs finalized transcript text before notes can be generated."
            case .contextTooSmall: "The selected model context is too small for the meeting instructions and user notes."
            }
        }
    }

    public static let version = "oatmeal-notes-v1"

    public static func build(meeting: Meeting, contextLimit: Int) throws -> String {
        let transcript = meeting.transcript.filter { $0.state == .final }.sorted { $0.startMS < $1.startMS }
        guard !transcript.isEmpty else { throw PromptError.noTranscript }
        let notes = meeting.userNotes.sorted { $0.meetingTimeMS < $1.meetingTimeMS }
        let reservedOutputTokens = min(1_024, max(1, contextLimit / 4))
        let maximumCharacters = max(1, contextLimit - reservedOutputTokens) * 4
        let noteLines = notes.map { "[\(timestamp($0.meetingTimeMS))] USER NOTE: \($0.text)" }.joined(separator: "\n")
        let header = """
            You are Oatmeal, a local meeting-notes assistant. Use only the source material below.
            Do not invent owners, dates, due dates, or decisions. If a section has no supported content, write "None identified."
            Return Markdown with exactly these top-level headings, in this order:
            # Summary
            # Decisions
            # Action Items
            # Open Questions
            # Important Context

            Meeting: \(meeting.title)
            Started: \(ISO8601DateFormatter().string(from: meeting.startedAt))

            USER NOTES
            \(noteLines.isEmpty ? "None" : noteLines)

            TRANSCRIPT

            """
        guard header.count < maximumCharacters else { throw PromptError.contextTooSmall }
        let transcriptText = transcript.map { "[\(timestamp($0.startMS))] \($0.source.label): \($0.text)" }.joined(separator: "\n")
        return header + String(transcriptText.prefix(maximumCharacters - header.count))
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}

public enum GeneratedNoteValidator {
    public enum ValidationError: LocalizedError, Equatable {
        case missingSection(String)
        public var errorDescription: String? {
            switch self { case let .missingSection(section): "Generated notes are missing \(section)." }
        }
    }

    public static let requiredHeadings = [
        "# Summary",
        "# Decisions",
        "# Action Items",
        "# Open Questions",
        "# Important Context",
    ]

    public static func validate(_ content: String) throws {
        let lines = Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        for heading in requiredHeadings where !lines.contains(heading) {
            throw ValidationError.missingSection(heading)
        }
    }
}

public protocol NoteGenerationEngine: Sendable {
    func validateModel() async throws
    func generate(prompt: String, contextLimit: Int) async throws -> String
}

public actor NoteGenerationService {
    public enum GenerationError: LocalizedError {
        case meetingNotFound
        public var errorDescription: String? { "The selected meeting no longer exists." }
    }

    private let engine: any NoteGenerationEngine
    private let store: MeetingStore
    private let modelIdentifier: String
    private let contextLimit: Int

    public init(engine: any NoteGenerationEngine, store: MeetingStore, modelIdentifier: String, contextLimit: Int = 8_192) {
        self.engine = engine
        self.store = store
        self.modelIdentifier = modelIdentifier
        self.contextLimit = contextLimit
    }

    @discardableResult
    public func generate(meetingID: UUID) async throws -> GeneratedNote {
        guard let meeting = try store.meeting(id: meetingID) else { throw GenerationError.meetingNotFound }
        try await engine.validateModel()
        let prompt = try PromptBuilder.build(meeting: meeting, contextLimit: contextLimit)
        let content = try await engine.generate(prompt: prompt, contextLimit: contextLimit).trimmingCharacters(in: .whitespacesAndNewlines)
        try GeneratedNoteValidator.validate(content)
        let note = GeneratedNote(
            meetingID: meetingID,
            modelIdentifier: modelIdentifier,
            promptVersion: PromptBuilder.version,
            content: content
        )
        try store.saveGeneratedNote(note)
        return note
    }
}

public struct LlamaProcessEngine: NoteGenerationEngine {
    public enum RuntimeError: LocalizedError {
        case missingExecutable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .missingExecutable: "The local llama.cpp runtime is missing."
            case let .failed(message): "Local note generation failed: \(message)"
            }
        }
    }

    public let executableURL: URL
    public let modelURL: URL
    public let argumentPrefix: [String]

    public init(executableURL: URL, modelURL: URL, argumentPrefix: [String] = []) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.argumentPrefix = argumentPrefix
    }

    public func validateModel() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw RuntimeError.missingExecutable }
        try ModelValidator.validate(url: modelURL, kind: .generation, minimumBytes: 1_000_000)
    }

    public func generate(prompt: String, contextLimit: Int) async throws -> String {
        try await validateModel()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argumentPrefix + [
            "-m", modelURL.path,
            "-p", prompt,
            "-c", String(contextLimit),
            "-n", String(min(1_024, max(256, contextLimit / 4))),
            "--temp", "0.2",
            "--single-turn",
            "--simple-io",
            "--no-display-prompt",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let captured = LockedData()
        let capturedErrors = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { captured.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capturedErrors.append(data) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    captured.append(output.fileHandleForReading.readDataToEndOfFile())
                    capturedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(data: captured.value, encoding: .utf8) ?? "")
                    } else {
                        let details = String(data: capturedErrors.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let message = details.flatMap { $0.isEmpty ? nil : $0 } ?? "exit \(process.terminationStatus)"
                        continuation.resume(throwing: RuntimeError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    public static func bundled(modelURL: URL, bundle: Bundle = .main) throws -> LlamaProcessEngine {
        if let executable = RuntimeLocator.executable(named: "llama-completion", bundle: bundle) {
            return .init(executableURL: executable, modelURL: modelURL)
        }
        if let executable = RuntimeLocator.executable(named: "llama-cli", bundle: bundle) {
            return .init(executableURL: executable, modelURL: modelURL)
        }
        guard let executable = RuntimeLocator.executable(named: "llama", bundle: bundle) else { throw RuntimeError.missingExecutable }
        return .init(executableURL: executable, modelURL: modelURL, argumentPrefix: ["cli"])
    }
}
