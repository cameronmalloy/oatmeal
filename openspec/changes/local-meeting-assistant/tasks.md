# Tasks: Local Meeting Assistant

## 1. Project Foundation

- [ ] 1.1 Create the macOS 14.0 Swift/SwiftUI application target for Apple Silicon and the feature/module boundaries described in `design.md`, and verify the app builds and launches in Debug configuration.
- [ ] 1.2 Define shared meeting lifecycle, audio-source, transcript-segment, user-note, generated-note, and model-configuration domain types, and verify domain unit tests compile without depending on UI or concrete inference runtimes.
- [ ] 1.3 Implement the explicit meeting lifecycle state machine (`idle` through `completed` plus failure/degraded states), and verify unit tests cover valid transitions and reject invalid/racy transitions.

## 2. Local Persistence

- [ ] 2.1 Create the SQLite schema/repository for meetings, finalized transcript segments, user notes, generated notes, and model configuration, and verify schema creation succeeds on a clean application data directory.
- [ ] 2.2 Implement transactional creation/update/read operations for meetings and finalized transcript segments, and verify repository tests preserve chronological timestamps and survive repository reinitialization.
- [ ] 2.3 Implement user-note and generated-note persistence including model identifier and prompt version, and verify CRUD tests do not mutate transcript source data.
- [ ] 2.4 Implement cascading meeting deletion for application-managed meeting artifacts, and verify a repository test removes transcript, user-note, and generated-note rows for the deleted meeting only.

## 3. Permissions and Audio Capture

- [ ] 3.1 Implement microphone permission detection/request UX, and verify a permission-denied test/manual fixture prevents normal capture and surfaces an actionable message.
- [ ] 3.2 Implement system-audio capture permission detection/request UX, and verify a permission-denied test/manual fixture prevents normal capture and surfaces an actionable message.
- [ ] 3.3 Implement the microphone capture adapter that emits normalized timestamped PCM chunks tagged as `microphone`, and verify a prerecorded/injected fixture produces correctly tagged chunks.
- [ ] 3.4 Implement the ScreenCaptureKit system-audio adapter that emits normalized timestamped PCM chunks tagged as `system`, and verify an injected/system capture test produces correctly tagged chunks without relying on microphone bleed.
- [ ] 3.5 Integrate both capture adapters with Start/Stop lifecycle behavior, and verify an integration test shows both sources can feed the same meeting while remaining logically separate.
- [ ] 3.6 Add capture-failure handling that preserves the meeting id and already-persisted data, and verify forced source failure transitions to a visible recoverable/degraded state.

## 4. Local Transcription

- [ ] 4.1 Define the runtime-independent `TranscriptionEngine` adapter contract and model-validation result types, and verify coordinator tests can run with a fake engine.
- [ ] 4.2 Integrate `whisper.cpp` as the initial local transcription adapter and verify a known speech fixture produces non-empty local transcript output with networking disabled.
- [ ] 4.3 Implement per-source bounded buffering/window assembly and timestamp propagation, and verify a multi-minute synthetic fixture does not cause unbounded queue/memory growth.
- [ ] 4.4 Implement incremental partial/final result handling while persisting only finalized transcript segments, and verify partial replacements do not create duplicate durable transcript rows.
- [ ] 4.5 Map microphone results to `Me` and system-audio results to `Others`, and verify source-label unit/integration tests for both streams.
- [ ] 4.6 Order persisted/displayed transcript segments by meeting timestamps rather than inference completion order, and verify an out-of-order fake-engine test renders the correct conversation order.
- [ ] 4.7 Implement curated in-app transcription-model provisioning with size/quality guidance, source links, disk-space validation, progress, cancellation, selection, and Application Support storage, and verify onboarding cannot finish until a downloaded model validates successfully.
- [ ] 4.8 Implement missing/invalid transcription-model gating before meeting start, and verify a meeting cannot enter normal `capturing` state when model validation fails.
- [ ] 4.9 Implement recoverable STT inference/backlog error status, and verify a forced failure after successful segments leaves prior finalized transcript rows readable.

## 5. Live Meeting Experience and User Notes

- [ ] 5.1 Build the active-meeting SwiftUI view with visible capture state, transcript stream, and Stop control, and verify a UI test observes state changes from idle to active to stopped.
- [ ] 5.2 Render transcript segments with `Me`/`Others` labels and chronological ordering, and verify a UI test with mixed fake segments displays the expected labels/order.
- [ ] 5.3 Add free-form user-note entry/editing during active capture without blocking capture/transcription services, and verify an integration/UI test can add notes while fake transcript events continue arriving.
- [ ] 5.4 Timestamp and persist user notes relative to the meeting timeline, and verify reopening the meeting preserves note order and content.
- [ ] 5.5 Implement app termination/relaunch recovery for already-persisted meeting/transcript data, and verify a persistence integration test reconstructs a partially completed meeting's durable text artifacts.

## 6. Local Note Generation

- [ ] 6.1 Define the runtime-independent `NoteGenerationEngine` contract and compatible-model validation behavior, and verify generation-service tests use a fake engine without concrete llama.cpp dependencies.
- [ ] 6.2 Integrate `llama.cpp` for compatible local GGUF models and verify an offline local inference smoke test returns generated text from a known small fixture/model configuration.
- [ ] 6.3 Implement deferred in-app note-generation model provisioning with the same download behavior, and verify the first generation request can download/select a compatible model while changed selection is used on the next request without changing meeting source data.
- [ ] 6.4 Implement versioned prompt assembly from meeting metadata, ordered finalized transcript, and timestamped user notes, and verify prompt tests include both source types with explicit `Me`/`Others` attribution.
- [ ] 6.5 Implement required structured Markdown output sections (Summary, Decisions, Action Items, Open Questions, Important Context), and verify generated-output validation detects missing top-level sections.
- [ ] 6.6 Add grounding instructions that prohibit invented owners/dates/decisions and test with a fixture lacking a due date to verify the prompt/output contract does not require one.
- [ ] 6.7 Implement long-transcript input preparation that stays within the selected local model's usable context while preserving user notes and chronological meaning, and verify an oversized synthetic transcript can be processed without exceeding the configured context budget.
- [ ] 6.8 Persist successful generated notes separately from transcript/user notes, and verify generation does not update source rows.
- [ ] 6.9 Implement regeneration with the same or a different local model, and verify regeneration succeeds from persisted source material without recapturing/retranscribing audio.
- [ ] 6.10 Preserve the last successful generated note when a later generation fails, and verify a forced failure leaves the prior note accessible and exposes retry.

## 7. Meeting History

- [ ] 7.1 Build a local meeting-history view showing title and meeting date/time, and verify a UI test displays multiple persisted meetings distinctly.
- [ ] 7.2 Implement meeting detail reopening for transcript, user notes, and latest successful generated notes, and verify a stored meeting can be reopened after application restart.
- [ ] 7.3 Implement meeting rename without mutating meeting source content, and verify repository/UI tests change only the displayed title metadata.
- [ ] 7.4 Implement confirmed meeting deletion, and verify deleted meeting artifacts disappear from history and application-managed storage while unrelated meetings remain intact.

## 8. Privacy and Network Independence

- [ ] 8.1 Ensure raw audio is never written to the meeting repository or permanent application storage during normal processing, and verify a completed-meeting storage inspection contains no application-created raw audio recording.
- [ ] 8.2 Audit transcription and generation paths to ensure meeting content is not sent to network APIs, and verify automated tests can complete core inference workflows in an environment where outbound networking is disabled.
- [ ] 8.3 Ensure diagnostics/telemetry configuration does not transmit meeting audio, transcript, user-note, generated-note, or prompt content, and verify logging tests redact/omit sensitive meeting payloads.
- [ ] 8.4 Verify explicit deletion removes persisted meeting text/metadata managed by the application, and document the local storage locations covered by deletion behavior.
- [ ] 8.5 Verify model-download requests contain no meeting content and that all capture, transcription, and generation workflows remain network-independent after provisioning.

## 9. End-to-End and Acceptance Verification

- [ ] 9.1 Add a deterministic interleaved microphone/system-audio fixture test covering capture-adapter output through transcription coordination, persistence, and `Me`/`Others` transcript rendering, and verify the expected transcript snapshot passes.
- [ ] 9.2 Add a failure-path integration test where STT fails after successful finalized segments, and verify the meeting remains reopenable with all previously persisted text.
- [ ] 9.3 Add an end-to-end local generation test using persisted transcript plus user notes, and verify the result contains all required note sections and source records are unchanged.
- [ ] 9.4 Perform manual acceptance testing on a supported macOS version using Mac speakers with a real conferencing application, and record that local/remote speech is captured and labeled correctly.
- [ ] 9.5 Perform manual acceptance testing with AirPods or another headphone output device, and record that remote system audio is transcribed without requiring acoustic microphone pickup.
- [ ] 9.6 Perform manual permission-denied/recovery acceptance tests for microphone and system-audio capture, and verify the app provides actionable recovery rather than silent partial capture.
- [ ] 9.7 Perform an offline end-to-end meeting test after models are provisioned, and verify Start -> transcript -> Stop -> generate -> reopen history succeeds without network connectivity.
- [ ] 9.8 Run the full automated test suite and a release-build smoke test, and verify all tests pass and the application launches with no unresolved blocking warnings/errors.
