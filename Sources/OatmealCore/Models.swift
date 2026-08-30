import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
}

public enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case me
    case others

    public init(_ audioSource: AudioSource) {
        self = audioSource == .microphone ? .me : .others
    }

    public var label: String { self == .me ? "Me" : "Others" }
}

public enum TranscriptState: String, Codable, Sendable {
    case partial
    case final
}

public enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case starting
    case capturing
    case degraded
    case stopping
    case finalizing
    case completed
    case failed
}

public struct Meeting: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var transcript: [TranscriptSegment]
    public var userNotes: [UserNote]
    public var generatedNotes: [GeneratedNote]

    public init(
        id: UUID = UUID(),
        title: String = "New Meeting",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: MeetingStatus = .idle,
        transcript: [TranscriptSegment] = [],
        userNotes: [UserNote] = [],
        generatedNotes: [GeneratedNote] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.transcript = transcript
        self.userNotes = userNotes
        self.generatedNotes = generatedNotes
    }

    public var latestGeneratedNote: GeneratedNote? {
        generatedNotes.max { $0.createdAt < $1.createdAt }
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var source: TranscriptSource
    public var startMS: Int64
    public var endMS: Int64
    public var text: String
    public var state: TranscriptState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        source: TranscriptSource,
        startMS: Int64,
        endMS: Int64,
        text: String,
        state: TranscriptState = .final,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.state = state
        self.createdAt = createdAt
    }
}

public struct UserNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var meetingTimeMS: Int64
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        meetingTimeMS: Int64,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.meetingTimeMS = meetingTimeMS
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GeneratedNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var modelIdentifier: String
    public var promptVersion: String
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        modelIdentifier: String,
        promptVersion: String,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.modelIdentifier = modelIdentifier
        self.promptVersion = promptVersion
        self.content = content
        self.createdAt = createdAt
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var transcriptionModelID: String?
    public var transcriptionModelPath: String?
    public var generationModelID: String?
    public var generationModelPath: String?

    public init(
        transcriptionModelID: String? = nil,
        transcriptionModelPath: String? = nil,
        generationModelID: String? = nil,
        generationModelPath: String? = nil
    ) {
        self.transcriptionModelID = transcriptionModelID
        self.transcriptionModelPath = transcriptionModelPath
        self.generationModelID = generationModelID
        self.generationModelPath = generationModelPath
    }
}
