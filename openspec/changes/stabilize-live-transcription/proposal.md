## Why

Live transcription can fall behind and repeatedly interrupt the user with the same dropped-audio alert. It also sends silence and non-speech audio to Whisper, allowing hallucinated phrases such as “okay” and “thank you” to appear in the transcript.

## What Changes

- Treat silence and non-speech audio as normal input that produces no partial or finalized transcript text and no error state.
- Keep audio capture ingestion responsive while local inference is running so ordinary capture callback cadence does not itself overflow the pipeline.
- Represent genuine sustained transcription overload as one non-modal degraded episode instead of repeated alerts, while preserving finalized transcript text and allowing recovery.
- Add deterministic coverage for silent/noisy audio, sustained dual-source capture, overload notification, and recovery.

## Capabilities

### New Capabilities

- `live-transcription-stability`: Defines speech-only transcript output, bounded live processing, and non-repeating overload behavior.

### Modified Capabilities

None.

## Impact

- Affects audio window assembly, transcription coordination, meeting workflow status, and active-meeting status presentation.
- Adds local-only audio fixtures and pipeline tests; no network service or persisted raw audio is introduced.
- No new production dependency is expected unless measurements show the existing local runtime cannot distinguish non-speech reliably.
