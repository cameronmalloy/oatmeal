## Purpose

Provide explicit, user-controlled capture of the user's microphone and macOS system audio so a meeting can be processed locally without a conferencing bot or provider integration.

## ADDED Requirements

### Requirement: User-controlled meeting capture

The system SHALL provide an explicit control that allows the user to start and stop meeting capture manually.

#### Scenario: Start a meeting
- **GIVEN** the required capture permissions are granted
- **WHEN** the user starts a new meeting
- **THEN** the system begins capturing the configured microphone source and system-audio source
- **AND** the application clearly indicates that capture is active

#### Scenario: Stop a meeting
- **GIVEN** a meeting capture is active
- **WHEN** the user stops the meeting
- **THEN** the system stops accepting new audio for that meeting
- **AND** the meeting remains available for transcript finalization and note generation

### Requirement: Separate local and remote audio sources

The system SHALL preserve the user's microphone audio and system audio as separate logical sources throughout the capture-to-transcription pipeline.

#### Scenario: Both sources contain speech
- **GIVEN** the user speaks into the microphone while remote participants are audible through system audio
- **WHEN** the audio is sent for transcription
- **THEN** microphone-originated speech is identifiable as the user's source
- **AND** system-audio-originated speech is identifiable as the remote source

### Requirement: Headphone-compatible system audio capture

The system SHALL capture system audio independently of the physical output device used by the user.

#### Scenario: User wears headphones
- **GIVEN** meeting audio is routed to wired, Bluetooth, or USB headphones supported by macOS
- **WHEN** meeting capture is active
- **THEN** remote participant audio routed through system audio remains available to the capture pipeline
- **AND** the system does not depend on the microphone hearing the headphone output

### Requirement: Capture permission handling

The system SHALL detect missing microphone or system-audio permissions before beginning normal capture and SHALL provide actionable status to the user.

#### Scenario: Microphone permission missing
- **GIVEN** microphone permission has not been granted
- **WHEN** the user attempts to start a meeting
- **THEN** the system does not begin incomplete capture as if it were normal
- **AND** the user is told that microphone permission is required and how to grant it

#### Scenario: System-audio permission missing
- **GIVEN** system-audio capture permission has not been granted
- **WHEN** the user attempts to start a meeting
- **THEN** the system does not begin incomplete capture as if it were normal
- **AND** the user is told that system-audio capture permission is required and how to grant it

### Requirement: Capture lifecycle resilience

The system MUST stop capture cleanly when the user ends the meeting or when the audio capture subsystem terminates unexpectedly, and MUST preserve already-produced transcript data.

#### Scenario: Capture subsystem fails mid-meeting
- **GIVEN** a meeting has already produced transcript segments
- **WHEN** one or both audio capture sources fail unexpectedly
- **THEN** already-persisted transcript segments remain available
- **AND** the system exposes a recoverable capture error rather than silently discarding the meeting
