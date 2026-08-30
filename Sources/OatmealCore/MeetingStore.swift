import Foundation
import SQLite3

public final class MeetingStore: @unchecked Sendable {
    public enum StoreError: LocalizedError, Equatable {
        case sqlite(String)
        case partialTranscript
        case emptyTitle

        public var errorDescription: String? {
            switch self {
            case let .sqlite(message): message
            case .partialTranscript: "Only finalized transcript segments can be stored."
            case .emptyTitle: "A meeting title cannot be empty."
            }
        }
    }

    public static func applicationDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Oatmeal", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("oatmeal.sqlite")
    }

    private let database: OpaquePointer
    private let lock = NSRecursiveLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let handle { sqlite3_close(handle) }
            throw StoreError.sqlite(message)
        }
        database = handle
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute(Self.schema)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func saveMeeting(_ meeting: Meeting) throws {
        try withStatement("""
            INSERT INTO meetings(id, title, started_at, ended_at, status, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                status = excluded.status,
                updated_at = excluded.updated_at
            """) { statement in
            bind(meeting.id.uuidString, at: 1, to: statement)
            bind(meeting.title, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, meeting.startedAt.timeIntervalSince1970)
            bind(meeting.endedAt, at: 4, to: statement)
            bind(meeting.status.rawValue, at: 5, to: statement)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func meetings() throws -> [Meeting] {
        try withStatement("SELECT id, title, started_at, ended_at, status FROM meetings ORDER BY started_at DESC") { statement in
            var result: [Meeting] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try meetingRow(statement)) }
            try verifyFinished(statement)
            return result
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        var meeting: Meeting? = try withStatement("SELECT id, title, started_at, ended_at, status FROM meetings WHERE id = ?") { statement in
            bind(id.uuidString, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError() }
            return try meetingRow(statement)
        }
        guard meeting != nil else { return nil }
        meeting?.transcript = try transcript(meetingID: id)
        meeting?.userNotes = try userNotes(meetingID: id)
        meeting?.generatedNotes = try generatedNotes(meetingID: id)
        return meeting
    }

    public func saveSegment(_ segment: TranscriptSegment) throws {
        guard segment.state == .final else { throw StoreError.partialTranscript }
        try withStatement("""
            INSERT OR REPLACE INTO transcript_segments(id, meeting_id, source, start_ms, end_ms, text, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(segment.id.uuidString, at: 1, to: statement)
            bind(segment.meetingID.uuidString, at: 2, to: statement)
            bind(segment.source.rawValue, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, segment.startMS)
            sqlite3_bind_int64(statement, 5, segment.endMS)
            bind(segment.text, at: 6, to: statement)
            sqlite3_bind_double(statement, 7, segment.createdAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func saveUserNote(_ note: UserNote) throws {
        try withStatement("""
            INSERT INTO user_notes(id, meeting_id, meeting_time_ms, text, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
            """) { statement in
            bind(note.id.uuidString, at: 1, to: statement)
            bind(note.meetingID.uuidString, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, note.meetingTimeMS)
            bind(note.text, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, note.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, note.updatedAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func saveGeneratedNote(_ note: GeneratedNote) throws {
        try withStatement("""
            INSERT INTO generated_notes(id, meeting_id, model_identifier, prompt_version, content, created_at)
            VALUES(?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(note.id.uuidString, at: 1, to: statement)
            bind(note.meetingID.uuidString, at: 2, to: statement)
            bind(note.modelIdentifier, at: 3, to: statement)
            bind(note.promptVersion, at: 4, to: statement)
            bind(note.content, at: 5, to: statement)
            sqlite3_bind_double(statement, 6, note.createdAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func renameMeeting(id: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.emptyTitle }
        try withStatement("UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?") { statement in
            bind(title, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            bind(id.uuidString, at: 3, to: statement)
            try stepDone(statement)
        }
    }

    public func deleteMeeting(id: UUID) throws {
        try withStatement("DELETE FROM meetings WHERE id = ?") { statement in
            bind(id.uuidString, at: 1, to: statement)
            try stepDone(statement)
        }
    }

    public func saveModelConfiguration(_ configuration: ModelConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        guard let json = String(data: data, encoding: .utf8) else { throw StoreError.sqlite("Could not encode model configuration.") }
        try withStatement("INSERT OR REPLACE INTO model_configuration(id, json) VALUES(1, ?)") { statement in
            bind(json, at: 1, to: statement)
            try stepDone(statement)
        }
    }

    public func modelConfiguration() throws -> ModelConfiguration {
        try withStatement("SELECT json FROM model_configuration WHERE id = 1") { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                if result == SQLITE_DONE { return ModelConfiguration() }
                throw databaseError()
            }
            guard let text = sqlite3_column_text(statement, 0) else { return ModelConfiguration() }
            return try JSONDecoder().decode(ModelConfiguration.self, from: Data(String(cString: text).utf8))
        }
    }

    private func transcript(meetingID: UUID) throws -> [TranscriptSegment] {
        try withStatement("""
            SELECT id, source, start_ms, end_ms, text, created_at
            FROM transcript_segments WHERE meeting_id = ? ORDER BY start_ms, end_ms, created_at
            """) { statement in
            bind(meetingID.uuidString, at: 1, to: statement)
            var result: [TranscriptSegment] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let id = UUID(uuidString: text(statement, 0)),
                    let source = TranscriptSource(rawValue: text(statement, 1))
                else { throw StoreError.sqlite("Invalid transcript row.") }
                result.append(.init(
                    id: id,
                    meetingID: meetingID,
                    source: source,
                    startMS: sqlite3_column_int64(statement, 2),
                    endMS: sqlite3_column_int64(statement, 3),
                    text: text(statement, 4),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
            }
            try verifyFinished(statement)
            return result
        }
    }

    private func userNotes(meetingID: UUID) throws -> [UserNote] {
        try withStatement("""
            SELECT id, meeting_time_ms, text, created_at, updated_at
            FROM user_notes WHERE meeting_id = ? ORDER BY meeting_time_ms, created_at
            """) { statement in
            bind(meetingID.uuidString, at: 1, to: statement)
            var result: [UserNote] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)) else { throw StoreError.sqlite("Invalid user-note row.") }
                result.append(.init(
                    id: id,
                    meetingID: meetingID,
                    meetingTimeMS: sqlite3_column_int64(statement, 1),
                    text: text(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            }
            try verifyFinished(statement)
            return result
        }
    }

    private func generatedNotes(meetingID: UUID) throws -> [GeneratedNote] {
        try withStatement("""
            SELECT id, model_identifier, prompt_version, content, created_at
            FROM generated_notes WHERE meeting_id = ? ORDER BY created_at
            """) { statement in
            bind(meetingID.uuidString, at: 1, to: statement)
            var result: [GeneratedNote] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)) else { throw StoreError.sqlite("Invalid generated-note row.") }
                result.append(.init(
                    id: id,
                    meetingID: meetingID,
                    modelIdentifier: text(statement, 1),
                    promptVersion: text(statement, 2),
                    content: text(statement, 3),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            }
            try verifyFinished(statement)
            return result
        }
    }

    private func meetingRow(_ statement: OpaquePointer) throws -> Meeting {
        guard
            let id = UUID(uuidString: text(statement, 0)),
            let status = MeetingStatus(rawValue: text(statement, 4))
        else { throw StoreError.sqlite("Invalid meeting row.") }
        return Meeting(
            id: id,
            title: text(statement, 1),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            endedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            status: status
        )
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? databaseError().localizedDescription
            sqlite3_free(error)
            throw StoreError.sqlite(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func verifyFinished(_ statement: OpaquePointer) throws {
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> StoreError { .sqlite(String(cString: sqlite3_errmsg(database))) }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Date?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let schema = """
        CREATE TABLE IF NOT EXISTS meetings(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            status TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS transcript_segments(
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            source TEXT NOT NULL CHECK(source IN ('me', 'others')),
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS transcript_time ON transcript_segments(meeting_id, start_ms);
        CREATE TABLE IF NOT EXISTS user_notes(
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            meeting_time_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS user_note_time ON user_notes(meeting_id, meeting_time_ms);
        CREATE TABLE IF NOT EXISTS generated_notes(
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            model_identifier TEXT NOT NULL,
            prompt_version TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS model_configuration(id INTEGER PRIMARY KEY CHECK(id = 1), json TEXT NOT NULL);
        """
}
