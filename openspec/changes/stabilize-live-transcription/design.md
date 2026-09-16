## Context

See `proposal.md` for motivation and `specs/live-transcription-stability/spec.md` for the behavioral contract.

Capture callbacks currently enter a 120-item `AsyncStream`. Its consumer assembles five-second windows and then awaits each transcription before reading more callbacks. With two active sources, inference latency therefore controls capture-queue drainage; overflow drops the oldest callback and assigns the same modal error on every drop.

Every assembled window is currently sent to `whisper-cli`, including silence. The runtime's default no-speech behavior is not a reliable gate, and every non-empty result is accepted as transcript text. An empty result is treated as an error, so silence cannot currently complete as a normal no-op.

## Goals / Non-Goals

**Goals:**

- Remove inference latency from the capture-ingestion path.
- Prevent silent and low-level non-speech windows from reaching inference.
- Bound queued audio by audio duration per source rather than callback count.
- Report one recoverable, non-modal status for each genuine overload episode.
- Preserve source ordering, finalized transcript durability, and ephemeral raw-audio handling.

**Non-Goals:**

- Speaker diarization or named-speaker attribution.
- Persisting audio for later retry.
- Guaranteeing lossless transcription when the selected runtime has less aggregate throughput than incoming speech for longer than the bounded backlog.
- Adding a downloadable VAD model before the lightweight local gate is measured and found insufficient.

## Decisions

### 1. Gate assembled windows before invoking Whisper

Use a deterministic frame-level signal-energy check on normalized PCM to identify windows with no meaningful audio activity. The threshold remains an injectable tuning value because microphone and system-audio levels vary by hardware. A skipped window returns a normal no-result outcome: it emits no partial, persists no final segment, and does not degrade the meeting.

This is preferred over adding a VAD model because it addresses silence and low-level steady noise without another model download, provisioning path, or runtime dependency. Whisper's decoding thresholds alone are not selected because the reported hallucinations already demonstrate that decoder confidence does not reliably reject this input.

### 2. Separate ingestion/assembly from inference

The capture stream consumer will only append PCM to the existing per-source assembler and enqueue completed windows. It will not await transcription. Separate per-source workers will consume bounded window queues, keeping order within each source while allowing microphone and system-audio inference to progress independently.

Queue limits will be expressed as pending audio duration per source. This prevents callback granularity from changing effective capacity and reuses the existing source-separated window representation. Silent windows are removed before entering the inference queues, reducing work without weakening the bound.

One worker for all sources was considered but retains the current coupling: continuous work from one source can delay the other, and two sources require greater-than-realtime serial throughput. Unbounded queues were rejected because meetings can run for hours and raw audio must remain ephemeral and memory-bounded.

### 3. Latch overload state per episode

The first discarded transcription window starts an overload episode and updates an inline degraded status. Further drops update its count or duration without creating another modal notification. Once pending work falls below a lower recovery threshold, the latch clears and capture returns to normal; a later overload can then begin a new episode.

Actionable setup, permission, and runtime failures may continue using the existing error presentation. Backlog is operational status rather than a blocking error, so it belongs in the active-meeting view.

### 4. Test at component boundaries with deterministic fixtures

Tests will use generated PCM and a controllably delayed fake transcriber. Silence tests will assert that inference is not invoked, no partial/final text is emitted, and status remains normal. Pipeline tests will feed equivalent durations using different callback sizes while inference is suspended, then verify bounded duration, source order, one overload episode, and recovery.

A short manual run with the configured real Whisper model remains useful for threshold calibration, but automated behavior must not depend on a downloaded model or live microphone input.

## Risks / Trade-offs

- **Quiet speech can resemble background noise** → Calibrate against quiet-speech and room-noise fixtures and retain one explicit threshold tuning point.
- **Two concurrent Whisper processes can increase memory pressure** → Limit concurrency to one worker per source and measure supported curated models; reduce worker concurrency if memory measurements require it while retaining decoupled ingestion.
- **Any bounded backlog can lose audio under sustained overload** → Make the loss explicit once per episode, preserve finalized text, and recover automatically when pressure falls.

## Migration Plan

No stored-data migration is required. Replace the live in-memory pipeline in place, retain the existing transcript schema, and roll back by restoring the prior coordinator behavior if release validation shows unacceptable speech suppression or resource use.
