import XCTest
@testable import OatmealCore

final class NoteGenerationTests: XCTestCase {
    func testPromptKeepsUserNotesLabelsAndGroundingRules() throws {
        let meeting = Meeting(
            title: "Planning",
            transcript: [
                .init(meetingID: fixedID, source: .me, startMS: 1_000, endMS: 2_000, text: "Ship it"),
                .init(meetingID: fixedID, source: .others, startMS: 3_000, endMS: 4_000, text: "Sounds good"),
            ],
            userNotes: [.init(meetingID: fixedID, meetingTimeMS: 2_500, text: "Important")]
        )

        let prompt = try PromptBuilder.build(meeting: meeting, contextLimit: 2_000)

        XCTAssertTrue(prompt.contains("[00:01] Me: Ship it"))
        XCTAssertTrue(prompt.contains("[00:03] Others: Sounds good"))
        XCTAssertTrue(prompt.contains("[00:02] USER NOTE: Important"))
        XCTAssertTrue(prompt.contains("Do not invent owners, dates, due dates, or decisions"))
        XCTAssertFalse(prompt.contains("Due date:"))
    }

    func testPromptStaysWithinBudgetAndAlwaysRetainsUserNotes() throws {
        var transcript: [TranscriptSegment] = []
        for index in 0..<100 {
            transcript.append(.init(
                meetingID: fixedID,
                source: .others,
                startMS: Int64(index * 1_000),
                endMS: Int64(index * 1_000 + 500),
                text: String(repeating: "word ", count: 100)
            ))
        }
        let meeting = Meeting(transcript: transcript, userNotes: [.init(meetingID: fixedID, meetingTimeMS: 4, text: "KEEP THIS NOTE")])

        let prompt = try PromptBuilder.build(meeting: meeting, contextLimit: 500)

        XCTAssertLessThanOrEqual(prompt.count, 2_000)
        XCTAssertTrue(prompt.contains("KEEP THIS NOTE"))
    }

    func testGeneratedOutputRequiresEveryTopLevelSection() {
        let complete = """
            # Summary
            Done
            # Decisions
            None
            # Action Items
            None
            # Open Questions
            None
            # Important Context
            None
            """

        XCTAssertNoThrow(try GeneratedNoteValidator.validate(complete))
        XCTAssertThrowsError(try GeneratedNoteValidator.validate(complete.replacingOccurrences(of: "# Decisions", with: "Decisions")))
    }

    func testFailedRegenerationPreservesSourcesAndLastSuccessfulNote() async throws {
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(id: fixedID, transcript: [.init(meetingID: fixedID, source: .me, startMS: 0, endMS: 1, text: "Source")])
        try store.saveMeeting(meeting)
        try store.saveSegment(meeting.transcript[0])
        try store.saveUserNote(.init(meetingID: meeting.id, meetingTimeMS: 1, text: "User source"))
        let success = "# Summary\nS\n# Decisions\nNone\n# Action Items\nNone\n# Open Questions\nNone\n# Important Context\nNone"
        let engine = FixtureNoteEngine(results: [.success(success), .failure(FixtureGenerationError.failed)])
        let service = NoteGenerationService(engine: engine, store: store, modelIdentifier: "fixture", contextLimit: 2_000)

        _ = try await service.generate(meetingID: meeting.id)
        do {
            _ = try await service.generate(meetingID: meeting.id)
            XCTFail("Expected regeneration failure")
        } catch {
            let reopened = try store.meeting(id: meeting.id)
            XCTAssertEqual(reopened?.transcript.map(\.text), ["Source"])
            XCTAssertEqual(reopened?.userNotes.map(\.text), ["User source"])
            XCTAssertEqual(reopened?.generatedNotes.count, 1)
            XCTAssertEqual(reopened?.latestGeneratedNote?.content, success)
        }
    }

    func testLlamaProcessDrainsLargeOutputWithoutBlocking() async throws {
        let directory = try temporaryDirectory()
        let executable = directory.appendingPathComponent("llama-cli")
        let script = "#!/bin/sh\nprintf '# Summary\\n'; /usr/bin/yes x | /usr/bin/head -c 100000\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("model.gguf")
        var modelData = Data("GGUF".utf8)
        modelData.append(Data(count: 1_000_000))
        try modelData.write(to: model)
        let engine = LlamaProcessEngine(executableURL: executable, modelURL: model)

        let output = try await engine.generate(prompt: "local", contextLimit: 2_000)

        XCTAssertGreaterThan(output.count, 90_000)
    }

    func testLlamaProcessUsesNonInteractiveChatArguments() async throws {
        let directory = try temporaryDirectory()
        let executable = directory.appendingPathComponent("llama-completion")
        let script = """
            #!/bin/sh
            case " $* " in *" --single-turn "*) ;; *) exit 2 ;; esac
            case " $* " in *" --simple-io "*) ;; *) exit 3 ;; esac
            case " $* " in *" -no-cnv "*) exit 4 ;; esac
            printf ok
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("model.gguf")
        var modelData = Data("GGUF".utf8)
        modelData.append(Data(count: 1_000_000))
        try modelData.write(to: model)
        let engine = LlamaProcessEngine(executableURL: executable, modelURL: model)

        let output = try await engine.generate(prompt: "local", contextLimit: 2_000)
        XCTAssertEqual(output, "ok")
    }

    func testRealLlamaNotesWhenConfigured() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["OATMEAL_REAL_LLAMA_MODEL"]
        else { throw XCTSkip("Set a real GGUF model path to run local note generation.") }
        let store = try MeetingStore(url: try databaseURL())
        let meeting = Meeting(id: fixedID, title: "Release planning", transcript: [
            .init(meetingID: fixedID, source: .me, startMS: 0, endMS: 1_000, text: "We decided to ship Friday."),
            .init(meetingID: fixedID, source: .others, startMS: 1_000, endMS: 2_000, text: "Cameron will prepare the release notes."),
        ])
        try store.saveMeeting(meeting)
        for segment in meeting.transcript { try store.saveSegment(segment) }
        let engine = try LlamaProcessEngine.bundled(modelURL: URL(fileURLWithPath: modelPath))
        let service = NoteGenerationService(engine: engine, store: store, modelIdentifier: "real", contextLimit: 2_048)

        let note = try await service.generate(meetingID: meeting.id)

        XCTAssertNoThrow(try GeneratedNoteValidator.validate(note.content))
        XCTAssertEqual(try store.meeting(id: meeting.id)?.generatedNotes.count, 1)
    }

    private var fixedID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }

    private func databaseURL() throws -> URL {
        try temporaryDirectory().appendingPathComponent("oatmeal.sqlite")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum FixtureGenerationError: Error { case failed }

private actor FixtureNoteEngine: NoteGenerationEngine {
    private var results: [Result<String, Error>]
    init(results: [Result<String, Error>]) { self.results = results }
    func validateModel() async throws {}
    func generate(prompt: String, contextLimit: Int) async throws -> String { try results.removeFirst().get() }
}
