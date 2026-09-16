## 1. Warm Whisper Runtime

- [ ] 1.1 Add deterministic transcription-runtime tests covering one startup per source, repeated-window model reuse, loopback-only arguments, source routing, startup failure, cancellation, and child-process cleanup; verify `swift test --filter TranscriptionTests` exercises every case.
- [ ] 1.2 Replace per-window `whisper-cli` execution with two managed `whisper-server` processes and in-memory multipart requests using Foundation APIs; verify `swift test --filter TranscriptionTests` passes without creating temporary WAV files.
- [ ] 1.3 Make runtime preparation idempotent and bounded by a startup timeout, and bound captured runtime error output; verify concurrent preparation and failed-readiness tests pass under `swift test --filter TranscriptionTests`.

## 2. Application Lifecycle and Packaging

- [ ] 2.1 Route model validation, microphone windows, and system windows through the warm runtime while preserving transcript ordering and error state; verify `swift test --filter 'TranscriptionTests|MeetingWorkflowTests'` passes.
- [ ] 2.2 Stop the old runtime on model replacement and application termination without stopping it between meetings using the same model; verify lifecycle tests observe no orphan fixture processes and a second meeting performs no new startup.
- [ ] 2.3 Locate `whisper-server` through the existing bundled/Homebrew runtime lookup and require it in release checks; verify the runtime-locator tests and `Tests/release-smoke.sh` pass with the Homebrew cask dependencies installed.

## 3. Latency and Regression Verification

- [ ] 3.1 Add an opt-in real-model latency test for curated Base English and Small English covering the first window and two concurrent sources; verify each five-second window finalizes within five seconds after submission.
- [ ] 3.2 Run the full Swift and UI test suites and verify all existing capture, transcript, model provisioning, concise-note prompt, and note-generation tests pass.
- [ ] 3.3 Run a two-minute live meeting with simultaneous microphone and system speech using Small English; verify transcript updates stay within one window, no audio-drop status appears, and no transcription process remains after quitting Oatmeal.
