## 1. Suppress non-speech transcription

- [x] 1.1 Add generated-PCM tests for digital silence, low-level steady noise, quiet speech after silence, and both audio sources; verify the current behavior is exposed with `swift test --filter TranscriptionTests`.
- [x] 1.2 Add one configurable frame-level activity threshold before Whisper inference and represent skipped non-speech as a normal no-result outcome; verify `swift test --filter TranscriptionTests` passes with no engine call, partial text, stored segment, or degraded state for non-speech.

## 2. Decouple capture from inference

- [x] 2.1 Add a delayed-transcriber workflow test that feeds equal audio durations as different callback sizes from both sources; verify the current capture-count overflow is reproduced with `swift test --filter MeetingWorkflowTests`.
- [x] 2.2 Split fast capture/window assembly from bounded per-source inference workers and enforce capacity by queued audio duration; verify `swift test --filter MeetingWorkflowTests` passes without drops while the delayed transcriber remains within aggregate capacity and preserves per-source meeting-time order.

## 3. Make overload recoverable and non-repeating

- [x] 3.1 Add deterministic overload and recovery coverage, then latch overload notification until queued duration falls below the recovery threshold; verify `swift test --filter MeetingWorkflowTests` reports one episode across repeated drops, preserves prior text, returns to normal, and permits a later new episode.
- [x] 3.2 Present backlog as inline active-meeting status while retaining modal errors for actionable failures; verify `xcodebuild test -project Oatmeal.xcodeproj -scheme Oatmeal -destination 'platform=macOS' -only-testing:OatmealUITests` shows no repeated backlog alert and leaves Stop usable.

## 4. Regression verification

- [x] 4.1 Run `swift test` and `Tests/release-smoke.sh`, and verify the full automated suite plus release smoke test pass without persisting application-managed raw audio.
- [ ] 4.2 Run a ten-minute local meeting containing alternating silence, microphone speech, and system speech with the supported curated transcription models; verify silence adds no text, routine capture causes no drops, source labels remain correct, and any forced overload appears once inline and recovers.
