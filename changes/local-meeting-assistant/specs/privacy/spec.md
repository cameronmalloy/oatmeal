## Purpose

Guarantee that sensitive meeting content is processed and stored locally by default, with no hidden cloud dependency, no telemetry containing meeting content, and no persistent raw-audio archive.

## ADDED Requirements

### Requirement: Meeting-content processing remains local

The system MUST NOT transmit captured audio, transcript text, user-authored notes, or generated meeting notes to external services as part of normal capture, transcription, storage, or note generation.

#### Scenario: Complete workflow without network
- **GIVEN** all required local models are already installed
- **AND** the Mac has no network connectivity
- **WHEN** the user captures, transcribes, ends, reopens, and generates notes for a meeting
- **THEN** the workflow remains functional without a network service

### Requirement: No persistent raw-audio recording by default

The system MUST treat raw captured audio as ephemeral processing data and SHALL discard audio buffers after they are no longer required for active transcription processing.

#### Scenario: Meeting finishes normally
- **GIVEN** a meeting has been captured and transcription has finalized
- **WHEN** the meeting ends
- **THEN** application storage contains no persisted raw meeting-audio recording created by the application
- **AND** the persisted meeting artifacts consist of derived text and metadata required by the product

### Requirement: No meeting-content telemetry

The system MUST NOT collect or transmit telemetry containing meeting audio, transcript text, user notes, generated notes, or model prompts containing meeting content.

#### Scenario: Application encounters an error
- **GIVEN** an error occurs while processing sensitive meeting content
- **WHEN** the system records diagnostic information locally
- **THEN** diagnostics do not automatically transmit the meeting content to an external telemetry service

### Requirement: Network independence after model provisioning

Normal meeting operation SHALL NOT depend on network availability after compatible local model artifacts are present.

#### Scenario: Network becomes unavailable mid-meeting
- **GIVEN** required local models are already installed
- **AND** a meeting is active
- **WHEN** network connectivity is lost
- **THEN** local audio capture and local transcription can continue
- **AND** post-meeting local note generation remains available

### Requirement: Explicit deletion removes meeting content from application storage

When a user deletes a meeting, the system SHALL remove the meeting's persisted transcript, user notes, generated notes, and associated metadata from the application's managed storage.

#### Scenario: Delete sensitive meeting
- **GIVEN** a stored meeting contains transcript and notes
- **WHEN** the user confirms deletion
- **THEN** those meeting artifacts are no longer available through the application
