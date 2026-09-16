## Why

Live transcription currently launches `whisper-cli` and reloads the selected model for every five-second audio window. With Whisper Small, model startup and CPU inference take long enough that the first transcript is delayed and concurrent microphone/system speech can outpace processing.

## What Changes

- Keep the selected Whisper model loaded in a local runtime instead of reloading it for every window.
- Provide enough independent transcription capacity for microphone and system-audio windows without blocking capture.
- Start, replace, and stop the runtime safely when the selected model or application lifecycle changes.
- Preserve offline-only processing, ephemeral raw audio, source ordering, cancellation, and actionable runtime failures.
- Add deterministic lifecycle tests plus real-model latency and sustained-throughput checks for the curated Base English and Small English models.

## Capabilities

### New Capabilities

- `live-transcription-latency`: Covers warm local model reuse, bounded transcript-update latency, dual-source throughput, and runtime lifecycle behavior.

### Modified Capabilities

None.

## Impact

- Affects the whisper.cpp runtime adapter, application workflow configuration, release runtime packaging checks, and transcription tests.
- Uses the existing local whisper.cpp installation; no cloud service, stored raw audio, or new model format is introduced.
