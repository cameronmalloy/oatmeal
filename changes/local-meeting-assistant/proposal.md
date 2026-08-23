# Local Meeting Assistant

## Why

Users need Granola-style meeting transcription and note generation without sending meeting audio, transcripts, or notes to a cloud service. A macOS-first local application can capture the user's microphone and the computer's meeting audio, transcribe both on-device, and generate useful notes with open-source local models while keeping meeting data on the Mac.

## What Changes

- Add a macOS desktop application that manually starts and stops meeting capture.
- Capture the user's microphone and system audio as separate logical sources so the transcript can distinguish **Me** from **Others** without speaker diarization.
- Transcribe meeting audio locally with an on-device speech-to-text model and expose partial/final transcript progress during a meeting.
- Persist the timestamped transcript locally and preserve it across application restarts.
- Allow the user to type lightweight notes during a meeting and associate those notes with the meeting timeline.
- Generate structured post-meeting notes locally from the transcript plus the user's notes, including summary, decisions, action items, open questions, and important context.
- Provide local meeting history so users can reopen, regenerate, and delete past meetings.
- Enforce a local-only privacy model: no cloud transcription, no cloud LLM calls, no telemetry, and no persisted raw audio by default.
- Gracefully recover from model or transcription failures without losing already-persisted transcript data.

### Explicitly Out of Scope for v1

- Automatic meeting detection or automatic start/stop.
- Calendar integrations.
- Zoom, Google Meet, Teams, or other provider-specific APIs/bots.
- Named-speaker diarization among remote participants.
- Cloud synchronization, cloud backup, or multi-device sync.
- Mobile or Windows applications.
- Permanent audio recording or playback.

## Capabilities

### New Capabilities

- `meeting-capture` — manually start/stop a meeting and capture microphone plus system audio on macOS.
- `local-transcription` — transcribe captured audio locally and surface transcription status/errors.
- `meeting-transcript` — maintain and persist a timestamped transcript labeled as Me or Others.
- `user-notes` — capture user-authored notes during a meeting and preserve their timing/order.
- `note-generation` — generate and regenerate structured meeting notes locally from transcript and user notes.
- `meeting-history` — list, reopen, rename, and delete locally stored meetings.
- `privacy` — guarantee local-only processing and default non-retention of raw audio.

### Modified Capabilities

None. This change introduces a new application and new capabilities.

## Impact

- New macOS application target using Swift/SwiftUI.
- New native audio-capture layer using macOS microphone and system-audio APIs.
- New local speech-to-text runtime integration.
- New local LLM runtime integration.
- New local persistence layer for meetings, transcript segments, user notes, generated notes, and model configuration.
- New permissions UX for microphone and system-audio capture.
- New automated unit/integration tests using deterministic prerecorded fixtures; live meetings are not required for the core test suite.
