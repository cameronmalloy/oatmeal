## Purpose

Make local meeting transcripts appear promptly and keep pace with concurrent microphone and system speech without sending audio off the Mac.

## ADDED Requirements

### Requirement: Transcription runtime is ready before capture

The system SHALL prepare the selected local transcription model once before accepting meeting audio and MUST NOT reload that model for each audio window.

#### Scenario: Meeting starts with a valid model
- **GIVEN** a supported transcription model is selected
- **WHEN** the user starts a meeting
- **THEN** capture begins only after the local transcription runtime is ready
- **AND** later windows reuse the prepared model

#### Scenario: Runtime preparation fails
- **GIVEN** the selected model or local runtime cannot be prepared
- **WHEN** the user starts a meeting
- **THEN** capture does not begin
- **AND** the system presents an actionable local-runtime error

### Requirement: Transcript updates have bounded latency

The system SHALL finalize each qualifying five-second speech window within five seconds after that window closes when using a curated Base English or Small English model on supported Apple Silicon hardware.

#### Scenario: First speech window
- **GIVEN** the local transcription runtime is ready
- **AND** a curated transcription model is selected
- **WHEN** the first qualifying speech window closes
- **THEN** its finalized transcript appears within five seconds

#### Scenario: Concurrent microphone and system speech
- **GIVEN** the local transcription runtime is ready
- **AND** microphone and system audio each produce qualifying speech windows
- **WHEN** both sources continue for at least two minutes
- **THEN** each source's finalized windows continue to appear within five seconds of closing
- **AND** no window is discarded because model initialization or cross-source serialization delayed inference

### Requirement: Runtime lifecycle follows configuration

The system MUST use only the currently selected model and MUST stop local transcription runtime processes when they are replaced or no longer needed.

#### Scenario: Selected model changes
- **GIVEN** a local transcription runtime is prepared for one model
- **WHEN** the user selects a different transcription model
- **THEN** the old runtime is stopped
- **AND** subsequent meetings use only the newly selected model

#### Scenario: Transcription is cancelled
- **GIVEN** transcription work is active
- **WHEN** the work or application is terminated
- **THEN** associated local runtime processes and temporary request files are removed
- **AND** no orphan transcription process remains

### Requirement: Warm transcription remains private and offline

The system MUST keep audio and transcript processing on the Mac, MUST NOT expose a local transcription endpoint beyond the loopback interface, and MUST NOT retain raw meeting audio after processing.

#### Scenario: Audio window is transcribed
- **GIVEN** the local transcription runtime is ready
- **WHEN** an audio window is submitted for transcription
- **THEN** the audio is delivered only to an application-controlled local runtime
- **AND** any temporary audio file is deleted after the request completes
- **AND** no network service outside the Mac receives audio or transcript data

#### Scenario: Local endpoint is inspected
- **GIVEN** the runtime uses an inter-process network endpoint
- **WHEN** that endpoint is active
- **THEN** it accepts connections only through the loopback interface
