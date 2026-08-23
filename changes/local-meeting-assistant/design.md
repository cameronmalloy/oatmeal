# Design: Local Meeting Assistant

## Context

See `proposal.md` for product motivation and scope. The application is a new macOS-only desktop product whose core constraint is that meeting content remains local. The architecture must support concurrent microphone and system-audio capture, incremental speech transcription, durable transcript persistence, user-authored notes, and local LLM summarization while remaining resilient to model failures and application restarts.

The v1 transcript model intentionally distinguishes only `Me` and `Others`. Remote named-speaker diarization is excluded because all remote participants arrive in the same system-audio mix and reliable named attribution would add material complexity beyond the core product value.

## Goals / Non-Goals

### Goals

- Native macOS capture that works whether meeting audio is played through speakers or headphones.
- Separate microphone and system-audio paths so the user's speech is known without diarization.
- Fully local transcription and note generation after model files are provisioned.
- Incremental, durable transcripts that survive failures better than a single end-of-meeting batch job.
- A small set of replaceable interfaces around transcription and LLM inference so model/runtime choices can evolve without rewriting meeting logic.
- Raw audio retained only in bounded in-memory processing buffers and discarded after transcription use.
- Deterministic testability of the pipeline with prerecorded fixtures.

### Non-Goals

- Named identification of remote speakers.
- Recording/playback product behavior.
- Automatic meeting discovery.
- Provider SDKs or meeting bots.
- Calendar, contacts, sharing, sync, collaboration, or cloud backup.
- Supporting arbitrary operating systems in v1.

## Decisions

### 1. Native Swift/SwiftUI application

Build the v1 UI and application lifecycle in Swift/SwiftUI.

**Rationale:** Audio permissions, ScreenCaptureKit, microphone capture, application lifecycle, sandboxing, and macOS distribution are central to the product. A native shell removes unnecessary bridging around the most platform-specific subsystem.

**Alternatives considered:**

- **Electron:** faster cross-platform UI development, but system-audio capture still requires native bridging and introduces a heavier runtime for a Mac-only v1.
- **Python desktop app:** fast model experimentation, but packaging, permissions, background audio lifecycle, and native UX are more fragile.

### 2. ScreenCaptureKit for system audio; AVAudioEngine/Core Audio for microphone input

Capture remote meeting sound using macOS system-audio capture and capture the user's speech from the selected microphone independently.

The capture layer exposes normalized PCM buffers with metadata:

```text
CapturedAudioChunk
- source: microphone | system
- startTime: monotonic meeting-relative timestamp
- duration
- sampleRate
- channels
- pcmData
```

The app does not combine these sources before transcription. Each stream is independently buffered so source identity survives inference.

**Rationale:** This supports headphones because capture taps the system-audio stream rather than depending on acoustic speaker output. Keeping sources separate also gives deterministic `Me` vs `Others` labels for free.

**Alternative considered:** Capturing only the microphone and relying on speaker bleed. Rejected because it fails with headphones and produces poor separation.

### 3. Adapter boundary for local transcription; initial runtime is whisper.cpp

Define an application-level transcription interface whose implementation consumes normalized chunks and produces timestamped transcript segments. The initial implementation integrates `whisper.cpp` with Apple Silicon acceleration where available.

Conceptual interface:

```text
TranscriptionEngine
- validateModel()
- startSession(configuration)
- submit(audioChunk)
- finalize()
- cancel()

TranscriptSegment
- id
- source: me | others
- startTime
- endTime
- text
- state: partial | final
```

Only final segments are durable source-of-truth transcript entries. Partial text is UI state and may be replaced as decoding converges.

**Rationale:** `whisper.cpp` is appropriate for a native local Mac application, but the rest of the product should not depend on Whisper-specific types or model layout.

**Alternatives considered:**

- **faster-whisper/Python sidecar:** strong performance and easy experimentation, but increases packaging/runtime complexity.
- **Apple Speech APIs:** may be useful in the future but do not satisfy the requirement that the product's core inference behavior be based on configurable open-source local models.

### 4. Bounded streaming pipeline rather than unbounded audio accumulation

Audio capture writes short chunks into bounded per-source queues. A transcription coordinator consumes those queues, performs any required resampling/VAD/chunk assembly, invokes transcription, and persists finalized segments immediately.

Target behavior, not a hard API contract:

```text
Capture callback
   -> small PCM chunk
   -> bounded queue
   -> transcription window assembler
   -> local STT
   -> final segment
   -> SQLite transaction
   -> UI update
```

Backpressure must be observable. The application must not silently grow memory without bound if inference falls behind realtime. If backlog becomes unhealthy, surface degraded transcription status and prioritize preserving already-finalized text.

**Rationale:** A 60–120 minute meeting cannot safely be treated as one in-memory audio blob, and durable incremental segments reduce data loss after crashes.

### 5. SQLite as the durable local store

Use SQLite through a thin repository layer. The exact Swift persistence library is an implementation detail; the logical model is:

```text
Meeting
- id
- title
- startedAt
- endedAt
- status
- createdAt
- updatedAt

TranscriptSegment
- id
- meetingId
- source
- startMs
- endMs
- text
- createdAt

UserNote
- id
- meetingId
- meetingTimeMs
- text
- createdAt
- updatedAt

GeneratedNote
- id
- meetingId
- modelIdentifier
- promptVersion
- content
- createdAt
- generationStatus

AppModelConfiguration
- transcriptionModelPath / identifier
- generationModelPath / identifier
- generation settings required by runtime
```

Use foreign keys and cascading deletion for meeting-owned text artifacts. Persist transcript finalization in small transactions during the meeting rather than holding the entire meeting until Stop.

**Rationale:** The data is relational, local, modest in volume, and must be queryable for history while supporting transactional durability.

**Alternative considered:** Flat JSON/Markdown per meeting. Simpler initially, but weaker for incremental durable writes, schema evolution, history queries, and transactional deletion.

### 6. llama.cpp adapter for configurable local GGUF note-generation models

Define a `NoteGenerationEngine` interface independent of a specific model family. The initial implementation uses `llama.cpp` and accepts compatible user-configured GGUF model artifacts.

Input to generation is a structured local document containing:

- meeting metadata;
- ordered finalized transcript segments with `Me`/`Others` labels and timestamps;
- ordered user notes with timestamps;
- a versioned system instruction defining the output schema and grounding rules.

The generated output is stored separately from source transcript/user notes. Every successful generation records model identifier and prompt version so future regeneration is explainable.

**Rationale:** Model quality and hardware fit evolve quickly. A runtime/model adapter keeps v1 flexible without turning model management into a large product surface.

### 7. Structured Markdown as generated-note storage format

Store the successful generated note as Markdown with stable top-level sections:

```markdown
# Summary

# Decisions

# Action Items

# Open Questions

# Important Context
```

The generation prompt requires evidence-grounded content and tells the model to omit/mark unknown fields rather than infer unsupported owners or dates.

**Rationale:** Markdown is human-readable, easy to render in SwiftUI, easy to copy/export later, and does not require a complex structured editor in v1.

**Alternative considered:** Strict JSON schema output. Useful for downstream automation, but adds repair/validation complexity not needed for the initial note-reading experience. A later capability can derive structured action items if required.

### 8. Raw audio is ephemeral and never part of the meeting repository

Raw PCM buffers live only in memory or runtime-owned temporary processing structures while needed for active transcription. The application repository exposes no `AudioRecording` entity and no feature for saving or replaying meeting audio.

If a transcription chunk fails, v1 reports the failure rather than persisting raw meeting audio indefinitely for later recovery.

**Rationale:** This strongly enforces the privacy posture and reduces the security impact of local storage. The trade-off is that text lost from an unrecoverable inference failure cannot always be reconstructed after the buffer is discarded.

### 9. State-machine-driven meeting lifecycle

Represent meeting lifecycle explicitly rather than deriving state from UI controls.

```text
idle
  -> starting
  -> capturing
  -> stopping
  -> finalizing
  -> completed

Failure states are associated with the current phase and preserve the meeting id and durable data where possible.
```

Capture and transcription components communicate through application services rather than directly mutating UI state.

**Rationale:** Permissions, two audio sources, asynchronous inference, stop/finalize behavior, and failures otherwise create race conditions that are difficult to reproduce.

### 10. Manual Start/Stop is the only v1 meeting trigger

Do not inspect running apps, browser tabs, calendars, or audio activity to infer meetings in v1.

**Rationale:** Manual control is privacy-friendly, deterministic, testable, and removes a large class of heuristics from the MVP.

## Data Flow

### During a meeting

```text
User presses Start
      |
      v
Validate permissions + local STT model
      |
      v
Create Meeting row
      |
      +-----------------------+
      |                       |
      v                       v
Microphone capture       System audio capture
      |                       |
      v                       v
source=mic chunks        source=system chunks
      |                       |
      +-----------+-----------+
                  v
       Transcription Coordinator
                  |
                  v
          Local STT adapter
                  |
                  v
      finalized TranscriptSegment
                  |
                  v
            SQLite commit
                  |
                  v
             Transcript UI

User typing ----------------------> UserNote -> SQLite
```

### After stopping

```text
Stop capture
   -> flush/finalize pending STT work
   -> mark meeting completed
   -> load finalized transcript + user notes
   -> assemble versioned generation prompt
   -> local LLM adapter
   -> validate minimum note structure
   -> persist successful GeneratedNote
   -> render notes
```

Generation is retryable and does not mutate the transcript/user-note source tables.

## Error Handling

### Permission failure

Do not create a normal active capture session until required permissions are available. Present the missing permission and a route to macOS settings.

### Audio source failure

Transition the meeting to a degraded/error state, stop or isolate the failed source as appropriate, persist any finalized transcript, and make the problem visible. Do not silently present the meeting as fully captured.

### STT backlog

Track queued audio duration and processing latency. If transcription falls materially behind realtime, expose degraded status. Bound the queue to protect memory. Prefer a clear incomplete-transcript state over process instability.

### STT inference error

Persisted final transcript segments remain valid. Surface the failure. Continue if the engine can recover; otherwise allow Stop and preserve the partial meeting.

### LLM generation error

Record the failed attempt only as diagnostic status if useful; do not replace the last successful generated note. Allow retry with the same or a different compatible model.

### Database error

Treat inability to persist finalized transcript as a high-severity meeting error because continuing indefinitely would create false confidence that data is safe. Surface the problem and stop cleanly when safe to do so.

## Testing Strategy

### Unit tests

- Meeting lifecycle state transitions.
- Source labeling (`microphone -> Me`, `system -> Others`).
- Audio chunk timestamp propagation and ordering.
- Transcript ordering when inference results complete out of order.
- Repository CRUD, cascade deletion, and transaction behavior.
- User-note timestamp/order persistence.
- Generation prompt assembly and prompt-version metadata.
- Generated Markdown minimum-section validation.
- Failure behavior that preserves prior successful data.

### Integration tests

Use prerecorded, synthetic/non-sensitive fixtures to drive the capture-adjacent processing pipeline without requiring a live Zoom/Meet call.

Test at minimum:

1. microphone-only fixture -> `Me` transcript;
2. system-only fixture -> `Others` transcript;
3. interleaved fixtures -> chronologically ordered mixed transcript;
4. multi-minute fixture -> bounded processing without unbounded memory growth;
5. forced STT failure after successful segments -> prior text survives;
6. completed transcript + user notes -> local generated Markdown with required sections;
7. forced LLM failure during regeneration -> prior generated note survives;
8. offline test environment -> core workflow does not make required network calls.

### Manual acceptance tests

- Zoom/Meet/Teams call while using Mac speakers.
- Same workflow while using AirPods or another headphone device.
- Permission-denied first run.
- Change audio output device before a meeting and confirm system audio remains capturable.
- Kill/relaunch app after transcript segments have persisted and confirm recovery of stored meeting data.

## Risks / Trade-offs

- **[Remote speaker attribution is coarse]** -> v1 labels all system-audio speech as `Others`; defer named diarization until core capture/transcription quality is proven.
- **[Whisper latency may fall behind on slower Macs/models]** -> support configurable model sizes, bounded queues, performance instrumentation, and degraded-status UX.
- **[System-audio API behavior can vary across macOS releases/devices]** -> isolate ScreenCaptureKit behind a capture adapter and maintain manual hardware/output-device acceptance tests.
- **[No raw-audio persistence limits recovery from failed chunks]** -> prioritize privacy; persist finalized text aggressively and clearly expose incomplete transcription when inference fails.
- **[Long transcripts can exceed local LLM context limits]** -> generation service SHALL prepare input using deterministic chunking/condensation when necessary while preserving user notes and the final note schema; keep this logic behind the generation service so it can evolve independently.
- **[Local models consume substantial disk/RAM]** -> validate model compatibility before meetings and surface understandable configuration errors instead of failing after capture starts.
- **[Model output can hallucinate]** -> use explicit grounding instructions, stable section schema, preserve source transcript for review, and never treat generated notes as authoritative source data.

## Migration Plan

This is a greenfield capability, so no data migration or backwards compatibility is required.

Recommended delivery order:

1. Establish app shell, permissions, persistence, and meeting lifecycle.
2. Prove two-source audio capture and fixture-based capture tests.
3. Add local incremental transcription and durable transcript UI.
4. Add in-meeting user notes.
5. Add local LLM generation and regeneration.
6. Add meeting history/rename/delete and privacy hardening.
7. Complete performance, offline, headphone, and failure acceptance testing.

Rollback for any incomplete development build is removal/disablement of the unfinished feature; there is no existing production data contract to preserve.
