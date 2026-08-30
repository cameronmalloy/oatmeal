# Oatmeal Local Meeting Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete macOS-first, local-only Oatmeal meeting assistant described by the approved OpenSpec change.

**Architecture:** A SwiftUI application target consumes a dependency-free `OatmealCore` Swift package. Core owns lifecycle, SQLite persistence, native audio capture, model provisioning, and process adapters for bundled whisper.cpp and llama.cpp command-line runtimes; the UI observes one `AppModel` on the main actor.

**Tech Stack:** Swift 5.10, SwiftUI, Observation, AVFoundation, ScreenCaptureKit, SQLite3, Foundation `Process` and `URLSession`, XCTest, Xcode 15.4.

**Spec:** `openspec/changes/local-meeting-assistant/design.md` and `openspec/changes/local-meeting-assistant/specs/*/spec.md`

## Global Constraints

- Deployment target is macOS 14.0 on Apple Silicon.
- Meeting audio, transcript, user notes, prompts, and generated notes never go to cloud inference or telemetry.
- Raw audio is bounded and ephemeral; temporary WAV files are deleted after local inference.
- Microphone audio maps to `Me`; system audio maps to `Others`.
- Only finalized transcript segments are persisted.
- No calendar integration, named-speaker diarization, sync, bots, automatic meeting detection, or permanent recording in v1.
- Use native frameworks and SQLite3; add no third-party Swift dependencies.

---

### Task 1: Buildable macOS project and domain contracts

**Files:**
- Create: `Package.swift`
- Create: `Oatmeal.xcodeproj/project.pbxproj`
- Create: `Sources/OatmealCore/Models.swift`
- Create: `Sources/OatmealCore/MeetingLifecycle.swift`
- Create: `Sources/OatmealApp/OatmealApp.swift`
- Test: `Tests/OatmealCoreTests/MeetingLifecycleTests.swift`

**Interfaces:**
- Produces: `Meeting`, `TranscriptSegment`, `UserNote`, `GeneratedNote`, `ModelConfiguration`, `AudioSource`, `MeetingStatus`, and `MeetingLifecycle.transition(to:)`.

- [ ] **Step 1: Write the failing lifecycle test**

```swift
func testLifecycleAcceptsCaptureFlowAndRejectsSkippingStart() throws {
    var lifecycle = MeetingLifecycle()
    XCTAssertThrowsError(try lifecycle.transition(to: .capturing))
    try lifecycle.transition(to: .starting)
    try lifecycle.transition(to: .capturing)
    try lifecycle.transition(to: .stopping)
    try lifecycle.transition(to: .finalizing)
    try lifecycle.transition(to: .completed)
    XCTAssertEqual(lifecycle.status, .completed)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter MeetingLifecycleTests`
Expected: compilation fails because `MeetingLifecycle` does not exist.

- [ ] **Step 3: Add the package, domain values, minimal transition table, SwiftUI entry point, Info.plist settings, and application target**

```swift
public mutating func transition(to next: MeetingStatus) throws {
    guard Self.allowed[status, default: []].contains(next) else {
        throw LifecycleError.invalidTransition(from: status, to: next)
    }
    status = next
}
```

- [ ] **Step 4: Verify GREEN and app compilation**

Run: `swift test --filter MeetingLifecycleTests && xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug -derivedDataPath /tmp/oatmeal-derived CODE_SIGNING_ALLOWED=NO build`
Expected: lifecycle test and Debug build pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Oatmeal.xcodeproj Sources Tests
git commit -m "feat: establish Oatmeal macOS app"
```

### Task 2: Durable SQLite meeting repository

**Files:**
- Create: `Sources/OatmealCore/MeetingStore.swift`
- Test: `Tests/OatmealCoreTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 domain values.
- Produces: `MeetingStore.init(url:)`, `saveMeeting`, `meetings`, `meeting(id:)`, `saveSegment`, `saveUserNote`, `saveGeneratedNote`, `renameMeeting`, and `deleteMeeting`.

- [ ] **Step 1: Write failing persistence and cascade tests**

```swift
func testFinalizedContentSurvivesReopenAndMeetingDeleteCascades() throws {
    let url = temporaryDatabaseURL()
    let meeting = Meeting(title: "Planning", startedAt: Date(timeIntervalSince1970: 10))
    try MeetingStore(url: url).saveMeeting(meeting)
    let reopened = try MeetingStore(url: url)
    try reopened.saveSegment(.init(meetingID: meeting.id, source: .me, startMS: 2, endMS: 5, text: "Hello"))
    XCTAssertEqual(try MeetingStore(url: url).meeting(id: meeting.id)?.transcript.map(\.text), ["Hello"])
    try reopened.deleteMeeting(id: meeting.id)
    XCTAssertNil(try reopened.meeting(id: meeting.id))
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter MeetingStoreTests`
Expected: compilation fails because `MeetingStore` does not exist.

- [ ] **Step 3: Implement one SQLite connection, schema migration, prepared statements, chronological reads, and foreign-key cascades**

```sql
PRAGMA foreign_keys = ON;
CREATE TABLE meetings(id TEXT PRIMARY KEY, title TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL, status TEXT NOT NULL);
CREATE TABLE transcript_segments(id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, source TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, text TEXT NOT NULL);
CREATE INDEX transcript_time ON transcript_segments(meeting_id, start_ms);
```

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter MeetingStoreTests`
Expected: repository tests pass after reopening the same file and cascading deletion.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/MeetingStore.swift Tests/OatmealCoreTests/MeetingStoreTests.swift
git commit -m "feat: persist local meeting artifacts"
```

### Task 3: Model catalog, validation, and downloads

**Files:**
- Create: `Sources/OatmealCore/ModelProvisioning.swift`
- Test: `Tests/OatmealCoreTests/ModelProvisioningTests.swift`

**Interfaces:**
- Produces: `ModelDescriptor`, `ModelCatalog.transcription`, `ModelCatalog.generation`, `ModelValidator.validate`, `ModelDownloader.download(_:to:progress:)`, and `DiskSpaceError`.

- [ ] **Step 1: Write the failing validation and disk-space tests**

```swift
func testValidatorRejectsMissingAndUndersizedModels() throws {
    let missing = URL(fileURLWithPath: "/tmp/oatmeal-missing-model")
    XCTAssertThrowsError(try ModelValidator.validate(url: missing, minimumBytes: 16))
    let tiny = temporaryFile(bytes: [0, 1, 2])
    XCTAssertThrowsError(try ModelValidator.validate(url: tiny, minimumBytes: 16))
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter ModelProvisioningTests`
Expected: compilation fails because model provisioning types do not exist.

- [ ] **Step 3: Add curated HTTPS descriptors, Application Support paths, free-space preflight with a 10% safety margin, cancellable download progress, atomic move, and size validation**

```swift
let required = descriptor.bytes + max(descriptor.bytes / 10, 100_000_000)
guard availableCapacity >= required else { throw DiskSpaceError.insufficient(required: required, available: availableCapacity) }
```

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter ModelProvisioningTests`
Expected: validation and storage-preflight tests pass without network access.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/ModelProvisioning.swift Tests/OatmealCoreTests/ModelProvisioningTests.swift
git commit -m "feat: provision local inference models"
```

### Task 4: Native two-source audio capture and bounded buffering

**Files:**
- Create: `Sources/OatmealCore/AudioCapture.swift`
- Test: `Tests/OatmealCoreTests/AudioCaptureTests.swift`

**Interfaces:**
- Produces: `CapturedAudioChunk`, `BoundedAudioBuffer`, `CapturePermissions`, `MicrophoneCapture`, `SystemAudioCapture`, and `DualCaptureCoordinator`.

- [ ] **Step 1: Write the failing source and capacity test**

```swift
func testBufferKeepsSourceAndDropsOldestChunkAtCapacity() async {
    let buffer = BoundedAudioBuffer(capacity: 2)
    await buffer.append(.fixture(source: .microphone, startMS: 1))
    await buffer.append(.fixture(source: .system, startMS: 2))
    await buffer.append(.fixture(source: .microphone, startMS: 3))
    let chunks = await buffer.drain()
    XCTAssertEqual(chunks.map(\.startMS), [2, 3])
    XCTAssertEqual(chunks.map(\.source), [.system, .microphone])
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter AudioCaptureTests`
Expected: compilation fails because `BoundedAudioBuffer` does not exist.

- [ ] **Step 3: Implement AVAudioEngine microphone capture, ScreenCaptureKit system-audio capture, monotonic timestamps, Float32 mono normalization, permission checks, and a shared stop path**

```swift
public actor BoundedAudioBuffer {
    public func append(_ chunk: CapturedAudioChunk) {
        chunks.append(chunk)
        if chunks.count > capacity { chunks.removeFirst(chunks.count - capacity) }
    }
}
```

- [ ] **Step 4: Verify GREEN and compile native adapters**

Run: `swift test --filter AudioCaptureTests && swift build`
Expected: buffer tests pass and AVFoundation/ScreenCaptureKit code compiles.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/AudioCapture.swift Tests/OatmealCoreTests/AudioCaptureTests.swift
git commit -m "feat: capture separate meeting audio sources"
```

### Task 5: Incremental local whisper.cpp transcription

**Files:**
- Create: `Sources/OatmealCore/Transcription.swift`
- Test: `Tests/OatmealCoreTests/TranscriptionTests.swift`

**Interfaces:**
- Produces: `TranscriptionEngine`, `WhisperProcessEngine`, `TranscriptionCoordinator`, `WAVEncoder`, and `TranscriptionStatus`.

- [ ] **Step 1: Write failing tests for WAV encoding, source labels, out-of-order finalization, and failure preservation**

```swift
func testCoordinatorPersistsFinalSegmentsInMeetingTimeOrder() async throws {
    let engine = FixtureTranscriber(results: [
        .init(source: .others, startMS: 20, endMS: 30, text: "Later"),
        .init(source: .me, startMS: 5, endMS: 10, text: "Earlier")
    ])
    let result = try await coordinator(engine: engine).transcribeFixtures()
    XCTAssertEqual(result.map(\.text), ["Earlier", "Later"])
    XCTAssertEqual(result.map(\.source), [.me, .others])
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `swift test --filter TranscriptionTests`
Expected: compilation fails because transcription contracts do not exist.

- [ ] **Step 3: Implement a runtime-independent engine, temporary WAV encoding, bounded window consumption, local `whisper-cli` process invocation, partial UI callbacks, and immediate finalized-segment persistence**

```swift
let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
defer { try? FileManager.default.removeItem(at: wavURL) }
```

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter TranscriptionTests`
Expected: deterministic fixture tests pass; the optional runtime smoke test skips unless executable and model paths are supplied.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/Transcription.swift Tests/OatmealCoreTests/TranscriptionTests.swift
git commit -m "feat: transcribe meeting audio locally"
```

### Task 6: Grounded local note generation

**Files:**
- Create: `Sources/OatmealCore/NoteGeneration.swift`
- Test: `Tests/OatmealCoreTests/NoteGenerationTests.swift`

**Interfaces:**
- Produces: `NoteGenerationEngine`, `LlamaProcessEngine`, `NoteGenerationService`, `PromptBuilder`, and `GeneratedNoteValidator`.

- [ ] **Step 1: Write failing prompt, context-budget, section-validation, and failed-regeneration tests**

```swift
func testPromptKeepsUserNotesAndDoesNotInventMissingMetadata() throws {
    let prompt = PromptBuilder.build(meeting: fixtureMeeting, contextLimit: 2_000)
    XCTAssertTrue(prompt.contains("USER NOTE"))
    XCTAssertTrue(prompt.contains("Do not invent owners, dates, due dates, or decisions"))
    XCTAssertFalse(prompt.contains("Due date:"))
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `swift test --filter NoteGenerationTests`
Expected: compilation fails because note-generation contracts do not exist.

- [ ] **Step 3: Implement prompt v1, chronological context trimming that always retains user notes, required Markdown validation, local `llama-cli` invocation, and persist-only-on-success regeneration**

```swift
public static let requiredHeadings = ["# Summary", "# Decisions", "# Action Items", "# Open Questions", "# Important Context"]
```

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter NoteGenerationTests`
Expected: all prompt and failure-preservation tests pass; optional local runtime smoke test skips without configured artifacts.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/NoteGeneration.swift Tests/OatmealCoreTests/NoteGenerationTests.swift
git commit -m "feat: generate grounded notes locally"
```

### Task 7: Application orchestration and recovery

**Files:**
- Create: `Sources/OatmealCore/MeetingWorkflow.swift`
- Create: `Sources/OatmealApp/AppModel.swift`
- Test: `Tests/OatmealCoreTests/MeetingWorkflowTests.swift`

**Interfaces:**
- Consumes: all core services from Tasks 1–6.
- Produces: testable `MeetingWorkflow` plus main-actor `AppModel` commands `startMeeting`, `stopMeeting`, `saveUserNote`, `generateNotes`, `renameMeeting`, `deleteMeeting`, and `reloadHistory`.

- [ ] **Step 1: Write a failing end-to-end core workflow test**

```swift
func testOfflineWorkflowPersistsTranscriptNotesAndGeneratedMarkdown() async throws {
    let workflow = fixtureWorkflow()
    let meetingID = try await workflow.start()
    try await workflow.accept(.fixture(source: .microphone, startMS: 1))
    try await workflow.addNote("Important", at: 2)
    try await workflow.stop()
    try await workflow.generate()
    let reopened = try workflow.store.meeting(id: meetingID)
    XCTAssertEqual(reopened?.transcript.first?.source, .me)
    XCTAssertEqual(reopened?.userNotes.first?.text, "Important")
    XCTAssertNotNil(reopened?.latestGeneratedNote)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter MeetingWorkflowTests`
Expected: compilation fails because workflow orchestration does not exist.

- [ ] **Step 3: Implement the single orchestration path used by both `AppModel` and tests, including model/permission gates, lifecycle transitions, active note timestamps, degraded errors, stop/finalize, and relaunch recovery of interrupted meetings**

```swift
do { try lifecycle.transition(to: next) }
catch { visibleError = error.localizedDescription; throw error }
```

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter MeetingWorkflowTests`
Expected: offline workflow and recovery tests pass with fixture inference/capture services.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealCore/MeetingWorkflow.swift Sources/OatmealApp/AppModel.swift Tests/OatmealCoreTests/MeetingWorkflowTests.swift
git commit -m "feat: coordinate resilient meeting workflow"
```

### Task 8: SwiftUI onboarding, live meeting, history, and model setup

**Files:**
- Create: `Sources/OatmealApp/ContentView.swift`
- Create: `Sources/OatmealApp/Info.plist`
- Create: `Sources/OatmealApp/Oatmeal.entitlements`
- Create: `UITests/OatmealUITests.swift`
- Modify: `Sources/OatmealApp/OatmealApp.swift`
- Modify: `Oatmeal.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: observable `AppModel` from Task 7.
- Produces: accessible Start/Stop, transcript, notes, history, rename/delete, generation, progress/cancel, and Open Models Folder UI.

- [ ] **Step 1: Add accessibility-identifier assertions to the workflow UI smoke harness**

```swift
XCTAssertNotNil(app.buttons["start-meeting"])
XCTAssertNotNil(app.outlines["meeting-history"])
XCTAssertNotNil(app.textViews["user-note"])
```

- [ ] **Step 2: Run the harness and verify RED**

Run: `xcodebuild test -project Oatmeal.xcodeproj -scheme Oatmeal -destination 'platform=macOS' -derivedDataPath /tmp/oatmeal-derived CODE_SIGNING_ALLOWED=NO -only-testing:OatmealUITests`
Expected: UI test compilation fails because the UI-test target and `ContentView` are absent.

- [ ] **Step 3: Build the minimum native SwiftUI views and permission/model error recovery actions**

```swift
NavigationSplitView {
    MeetingHistoryView(model: model)
} detail: {
    MeetingDetailView(model: model)
}
```

- [ ] **Step 4: Verify GREEN and launch smoke test**

Run: `swift test && xcodebuild test -project Oatmeal.xcodeproj -scheme Oatmeal -destination 'platform=macOS' -derivedDataPath /tmp/oatmeal-derived CODE_SIGNING_ALLOWED=NO`
Expected: all core and UI smoke tests pass and the Debug application builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/OatmealApp UITests Oatmeal.xcodeproj
git commit -m "feat: add Oatmeal meeting interface"
```

### Task 9: Privacy, release, and OpenSpec acceptance reconciliation

**Files:**
- Create: `Tests/OatmealCoreTests/PrivacyTests.swift`
- Create: `docs/privacy.md`
- Modify: `openspec/changes/local-meeting-assistant/tasks.md`

**Interfaces:**
- Consumes: completed application.
- Produces: automated storage/network/privacy evidence and a precise manual-acceptance checklist.

- [ ] **Step 1: Write the failing storage inspection test**

```swift
func testCompletedMeetingStorageContainsNoAudioFiles() throws {
    let root = try completedFixtureWorkflowDirectory()
    let extensions = try FileManager.default.subpathsOfDirectory(atPath: root.path).compactMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }
    XCTAssertTrue(Set(extensions).isDisjoint(with: ["wav", "aiff", "m4a", "caf", "pcm"]))
}
```

- [ ] **Step 2: Run the test and verify RED against the unfinished workflow fixture**

Run: `swift test --filter PrivacyTests`
Expected: test fails until the workflow fixture completes and temporary WAV cleanup is wired.

- [ ] **Step 3: Remove any persistent audio path, redact diagnostics to identifiers/status only, document Application Support paths, and mark only objectively completed OpenSpec checks**

```swift
logger.error("Inference failed for meeting \(meetingID.uuidString, privacy: .private(mask: .hash))")
```

- [ ] **Step 4: Run full verification**

Run: `swift test && xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Release -derivedDataPath /tmp/oatmeal-release CODE_SIGNING_ALLOWED=NO build && git diff --check`
Expected: all tests pass, Release builds, and the diff has no whitespace errors.

- [ ] **Step 5: Record the remaining manual checks**

Run on a signed macOS 14+ app: grant/deny microphone and Screen Recording permissions; capture speaker and AirPods calls; provision both models; disconnect networking; complete Start → transcript → Stop → generate → reopen → delete.

- [ ] **Step 6: Commit**

```bash
git add Tests docs/privacy.md openspec/changes/local-meeting-assistant/tasks.md
git commit -m "test: verify Oatmeal privacy and acceptance"
```

### Task 10: Homebrew cask and signed DMG release packaging

**Files:**
- Create: `scripts/release.sh`
- Create: `Casks/oatmeal.rb`
- Create: `.github/workflows/release.yml`
- Test: `Tests/release-smoke.sh`

**Interfaces:**
- Consumes: the verified Release application target and optional Apple signing/notarization credentials.
- Produces: `Oatmeal.dmg`, its SHA-256 digest, a GitHub release asset, and a Homebrew cask for Apple Silicon macOS 14+.

- [ ] **Step 1: Write a failing release smoke script**

```bash
test -f Oatmeal.dmg
hdiutil verify Oatmeal.dmg
codesign --verify --deep --strict "$mounted_app"
brew style Casks/oatmeal.rb
```

- [ ] **Step 2: Verify RED**

Run: `bash Tests/release-smoke.sh`
Expected: FAIL because the DMG and cask do not exist.

- [ ] **Step 3: Add one release script that archives arm64, signs when `DEVELOPER_ID_APPLICATION` is set, notarizes when the notary environment is set, creates a read-only DMG, and prints its SHA-256**

```bash
xcodebuild archive -project Oatmeal.xcodeproj -scheme Oatmeal -archivePath "$archive_path" -destination 'generic/platform=macOS'
hdiutil create -volname Oatmeal -srcfolder "$staging_path" -ov -format UDZO Oatmeal.dmg
shasum -a 256 Oatmeal.dmg
```

- [ ] **Step 4: Add `Casks/oatmeal.rb` for `https://github.com/cameronmalloy/oatmeal/releases/download/v#{version}/Oatmeal.dmg` and a tag-driven GitHub release workflow**

```ruby
cask "oatmeal" do
  version "0.1.0"
  url "https://github.com/cameronmalloy/oatmeal/releases/download/v#{version}/Oatmeal.dmg"
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64
  app "Oatmeal.app"
end
```

- [ ] **Step 5: Verify release packaging locally**

Run: `bash scripts/release.sh 0.1.0 && bash Tests/release-smoke.sh`
Expected: unsigned local DMG verifies and installs; signed CI releases additionally pass Gatekeeper/notarization checks.
