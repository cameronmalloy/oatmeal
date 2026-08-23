## Purpose

Convert captured meeting speech into text entirely on the local Mac while providing timely progress, recoverable failures, and source metadata needed by the meeting transcript.

## ADDED Requirements

### Requirement: Local speech transcription

The system SHALL transcribe captured meeting audio using an on-device speech-to-text runtime and MUST NOT require a network service for transcription.

#### Scenario: Transcribe captured speech offline
- **GIVEN** a compatible transcription model is installed locally
- **AND** the Mac has no network connectivity
- **WHEN** speech is captured during a meeting
- **THEN** the system can produce transcript text from that speech locally

### Requirement: Incremental transcription

The system SHALL process meeting audio incrementally so transcript content can appear before the meeting ends.

#### Scenario: Transcript progresses during a meeting
- **GIVEN** a meeting is actively capturing speech
- **WHEN** sufficient audio has accumulated for transcription
- **THEN** the system emits transcript segments during the meeting
- **AND** the user does not have to stop the meeting before seeing transcript progress

### Requirement: Source-aware transcription output

Every finalized transcript segment SHALL retain the logical source from which its audio originated.

#### Scenario: Microphone segment is finalized
- **GIVEN** a finalized segment was transcribed from microphone audio
- **WHEN** the segment is emitted to transcript storage
- **THEN** the segment identifies its source as the user

#### Scenario: System-audio segment is finalized
- **GIVEN** a finalized segment was transcribed from system audio
- **WHEN** the segment is emitted to transcript storage
- **THEN** the segment identifies its source as remote participants

### Requirement: Timestamped transcript output

Every finalized transcript segment SHALL include timing sufficient to place it in chronological order within the meeting.

#### Scenario: Two segments complete out of processing order
- **GIVEN** two audio segments originate at different meeting times
- **AND** transcription processing completes them in a different order
- **WHEN** they are stored in the meeting transcript
- **THEN** their timestamps allow the transcript to present them in meeting-time order

### Requirement: Recoverable transcription failure

A transcription failure MUST NOT delete previously finalized transcript segments or invalidate the entire meeting.

#### Scenario: Model inference fails for one chunk
- **GIVEN** prior transcript segments have been finalized and persisted
- **WHEN** transcription fails for a later audio chunk
- **THEN** the existing transcript remains readable
- **AND** the application exposes a transcription error state
- **AND** capture can continue or be stopped without losing the existing transcript

### Requirement: Missing transcription model handling

The system SHALL detect when no usable local transcription model is configured and SHALL prevent a meeting from appearing to transcribe successfully.

#### Scenario: Start meeting without a model
- **GIVEN** no compatible transcription model is available
- **WHEN** the user attempts to start a meeting
- **THEN** the system reports that a local transcription model is required
- **AND** the system does not present empty transcription as successful transcription

### Requirement: In-app transcription-model provisioning

The system SHALL let the user download and select a supported transcription model in the application without requiring Terminal or manual file placement.

#### Scenario: Provision a model during onboarding
- **GIVEN** no compatible transcription model is installed
- **WHEN** the user opens model setup
- **THEN** the system presents a curated model list with name, download size, speed/quality guidance, and source
- **AND** the user can download a model with visible progress and a Cancel action
- **AND** a successful download is stored in the application's Application Support directory and selected for transcription

#### Scenario: Insufficient disk space
- **GIVEN** the Mac lacks enough free space for the selected model and a safety margin
- **WHEN** the user attempts to download it
- **THEN** the system does not start the download
- **AND** the system displays an actionable storage error
