## Context

See `proposal.md` for motivation and `specs/live-transcription-latency/spec.md` for the behavioral contract.

`WhisperProcessEngine` currently writes every five-second window to a temporary WAV, launches `whisper-cli`, and passes the model path to that new process. A local benchmark with the configured 465 MB Small English model took about 4.2 seconds for one window and about 6 seconds per window when microphone and system jobs ran concurrently. The installed whisper.cpp package also provides `whisper-server`, which loads a model once and accepts WAV input over loopback HTTP; a warmed Small English request took about 2.6 seconds.

The stabilized meeting workflow already owns bounded, source-separated queues and one worker per source. The runtime adapter therefore needs to remove repeated model startup without changing capture, storage, or transcript ordering.

## Goals / Non-Goals

**Goals:**

- Reuse a loaded model across all windows for the same selected model.
- Preserve independent microphone and system inference capacity.
- Use only loopback IPC and in-memory request bodies.
- Make startup, cancellation, model replacement, and process cleanup deterministic.

**Non-Goals:**

- Replacing whisper.cpp, changing the GGML model format, or adding a cloud fallback.
- Changing the existing five-second window size or backlog policy.
- Adding streaming token transport; each short window may complete as one response.
- Enabling the crashing Homebrew Metal path before it is stable on supported hardware.

## Decisions

### 1. Reuse the installed `whisper-server` runtime

Replace per-window `whisper-cli` launches with managed `whisper-server` processes. Each process starts with the selected model, `--no-gpu`, a loopback host, and an application-chosen port. The app submits the existing WAV bytes as multipart data using `URLSession`, so no new package or durable audio file is needed.

Directly linking the whisper.cpp C API was considered but rejected because it adds build, packaging, and Swift interop work for behavior already supplied by the installed runtime. `whisper-stream` was rejected because it owns microphone capture and does not fit Oatmeal's separate normalized microphone and system-audio windows.

### 2. Keep one warm process per audio source

The engine owns two server processes keyed by `AudioSource`. This matches the workflow's two existing workers and prevents one source from serializing the other. A single shared server was rejected because its requests serialized in the measured runtime and could not guarantee the dual-source latency target. Launching `whisper-cli` concurrently was also rejected because both processes still reload the model for every window.

The memory cost is two loaded model copies while transcription is configured. This is intentional for the two fixed sources; no general worker pool or dynamic scaling is introduced.

### 3. Prepare idempotently and fail before capture

`validateModel()` becomes the preparation boundary. It validates the model and executable, starts any missing source runtime, and waits with a short timeout until each loopback endpoint responds. Concurrent preparation calls share the same in-flight work. A child exit, timeout, or invalid response becomes an actionable startup error and capture does not begin.

The runtime remains warm across meetings while the same workflow/model is configured. Replacing the configured transcription engine or terminating the app stops both child processes. A stopped or unexpectedly exited process is prepared again on the next meeting start rather than silently falling back to the slow CLI path.

### 4. Keep requests local, cancellable, and source ordered

Each source worker sends one request at a time to its assigned endpoint. The response body supplies the finalized text to the existing coordinator; the existing source queue preserves ordering. Task cancellation cancels the HTTP request, and engine shutdown terminates its child processes and invalidates its URL session.

Servers bind explicitly to `127.0.0.1`, never a wildcard address. Request WAV data stays in memory, and no raw audio is added to application storage. Runtime logs are captured only for local error reporting and are bounded to prevent unbounded memory growth.

### 5. Verify behavior at the adapter and release boundaries

Deterministic tests use a local fixture server/process to verify one startup per source, model reuse, source routing, error propagation, cancellation, and cleanup. Existing workflow tests continue to cover queue ordering and overload behavior.

An opt-in real-model test measures the first and sustained two-source windows using the curated Base English and Small English models. Release smoke checks require `whisper-server` wherever `whisper-cli` is currently required.

## Risks / Trade-offs

- **Two model copies increase memory use** → Limit the design to the two existing audio sources and verify Base and Small on the minimum supported Apple Silicon configuration.
- **A loopback port can collide or be probed by another local process** → Choose unused high ports per launch, bind only to `127.0.0.1`, and fail closed if readiness identifies the wrong process.
- **The server can exit during a meeting** → Surface one actionable runtime failure and let the bounded workflow remain stoppable; prepare a clean runtime on the next meeting.
- **CPU-only performance varies by hardware** → Gate release support with the explicit real-model latency test and keep Base English available as the lower-cost option.

## Migration Plan

Require and locate `whisper-server` beside the existing whisper.cpp CLI, switch the adapter in place, and retain the current transcript and model configuration formats. Roll back by restoring `WhisperProcessEngine`; no stored-data migration is required.
