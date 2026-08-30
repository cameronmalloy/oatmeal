import XCTest
@testable import OatmealCore

final class MeetingStoreTests: XCTestCase {
    func testFinalizedContentSurvivesReopenInChronologicalOrder() throws {
        let url = try databaseURL()
        let meeting = Meeting(title: "Planning", startedAt: Date(timeIntervalSince1970: 10), status: .capturing)
        try MeetingStore(url: url).saveMeeting(meeting)

        let reopened = try MeetingStore(url: url)
        try reopened.saveSegment(.init(meetingID: meeting.id, source: .others, startMS: 20, endMS: 25, text: "Later"))
        try reopened.saveSegment(.init(meetingID: meeting.id, source: .me, startMS: 2, endMS: 5, text: "Earlier"))
        try reopened.saveUserNote(.init(meetingID: meeting.id, meetingTimeMS: 3, text: "Remember this"))
        try reopened.saveGeneratedNote(.init(meetingID: meeting.id, modelIdentifier: "local-model", promptVersion: "v1", content: "# Summary\nDone"))

        let stored = try MeetingStore(url: url).meeting(id: meeting.id)
        XCTAssertEqual(stored?.transcript.map(\.text), ["Earlier", "Later"])
        XCTAssertEqual(stored?.userNotes.map(\.text), ["Remember this"])
        XCTAssertEqual(stored?.latestGeneratedNote?.modelIdentifier, "local-model")
    }

    func testPartialTranscriptIsNeverPersisted() throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting()
        try store.saveMeeting(meeting)

        XCTAssertThrowsError(try store.saveSegment(.init(
            meetingID: meeting.id,
            source: .me,
            startMS: 0,
            endMS: 1,
            text: "still changing",
            state: .partial
        )))
        XCTAssertEqual(try store.meeting(id: meeting.id)?.transcript, [])
    }

    func testRenameChangesOnlyTitleAndDeleteCascadesOnlySelectedMeeting() throws {
        let store = try MeetingStore(url: try databaseURL())
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        try store.saveMeeting(first)
        try store.saveMeeting(second)
        try store.saveSegment(.init(meetingID: first.id, source: .me, startMS: 1, endMS: 2, text: "First transcript"))
        try store.saveSegment(.init(meetingID: second.id, source: .others, startMS: 1, endMS: 2, text: "Second transcript"))

        try store.renameMeeting(id: first.id, title: "Renamed")
        XCTAssertEqual(try store.meeting(id: first.id)?.title, "Renamed")
        XCTAssertEqual(try store.meeting(id: first.id)?.transcript.map(\.text), ["First transcript"])

        try store.deleteMeeting(id: first.id)
        XCTAssertNil(try store.meeting(id: first.id))
        XCTAssertEqual(try store.meeting(id: second.id)?.transcript.map(\.text), ["Second transcript"])
    }

    func testConfigurationSurvivesReopen() throws {
        let url = try databaseURL()
        let configuration = ModelConfiguration(
            transcriptionModelID: "whisper-small",
            transcriptionModelPath: "/models/whisper.bin",
            generationModelID: "qwen",
            generationModelPath: "/models/qwen.gguf"
        )
        let store = try MeetingStore(url: url)
        try store.saveModelConfiguration(configuration)

        XCTAssertEqual(try MeetingStore(url: url).modelConfiguration(), configuration)
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("oatmeal.sqlite")
    }
}
