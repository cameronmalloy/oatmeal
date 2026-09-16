## Purpose

Keep live transcription responsive and trustworthy by emitting text only for speech and handling processing pressure without repeated user interruption or loss of finalized text.

## ADDED Requirements

### Requirement: Non-speech audio is ignored

The system SHALL treat silence and low-level non-speech audio as normal input that produces no transcript content and MUST NOT report skipped non-speech as a transcription failure.

#### Scenario: Silent audio window
- **GIVEN** meeting capture is active
- **WHEN** an audio window contains silence
- **THEN** the system emits no partial or finalized transcript text for that window
- **AND** the meeting remains in its normal capture state

#### Scenario: Low-level non-speech noise
- **GIVEN** meeting capture is active
- **WHEN** an audio window contains only low-level background noise and no speech activity
- **THEN** the system emits no partial or finalized transcript text for that window
- **AND** no transcript segment is persisted for that window

#### Scenario: Speech follows silence
- **GIVEN** silent or non-speech windows were ignored
- **WHEN** a later audio window contains speech
- **THEN** the speech is eligible for normal partial and finalized transcription
- **AND** its source and meeting-relative timing remain correct

### Requirement: Live capture is isolated from inference latency

The system SHALL continue accepting and assembling microphone and system-audio input while earlier windows are being transcribed. Ordinary differences in callback size or frequency MUST NOT by themselves cause captured audio to be dropped.

#### Scenario: Equivalent audio arrives in different callback sizes
- **GIVEN** two capture sources provide the same duration of audio
- **AND** one source provides many small callbacks while the other provides fewer large callbacks
- **WHEN** local transcription is processing an earlier window
- **THEN** both sources' later audio remains eligible for transcription
- **AND** the meeting does not enter a degraded state solely because of callback count

#### Scenario: Sustained dual-source capture within capacity
- **GIVEN** microphone and system audio are captured concurrently
- **AND** the configured local transcription runtime has sufficient aggregate throughput for the incoming speech
- **WHEN** capture continues across multiple transcription windows
- **THEN** the system does not discard unprocessed audio
- **AND** finalized transcript segments remain ordered by meeting time

### Requirement: Sustained overload is bounded and non-repeating

The system MUST keep pending raw audio bounded in memory. If sustained inference overload requires unprocessed audio to be discarded, the system SHALL expose one non-modal degraded episode, preserve finalized transcript text, and remain controllable.

#### Scenario: Processing remains slower than incoming speech
- **GIVEN** the bounded transcription backlog has reached capacity
- **WHEN** additional speech arrives before processing recovers
- **THEN** the system discards only unprocessed audio according to its documented backlog policy
- **AND** exposes degraded transcription status without repeatedly presenting modal alerts
- **AND** previously finalized transcript segments remain readable
- **AND** the user can still stop the meeting

#### Scenario: Repeated drops during one overload episode
- **GIVEN** degraded transcription status is already visible for the current overload episode
- **WHEN** more unprocessed audio must be discarded before recovery
- **THEN** the system updates the existing degraded status rather than notifying the user again

#### Scenario: Processing recovers
- **GIVEN** the system reported a transcription overload
- **WHEN** pending transcription work returns below the recovery threshold
- **THEN** the active meeting returns to normal capture status
- **AND** a later distinct overload can be reported as a new episode

### Requirement: Skipped audio remains ephemeral

The system MUST NOT persist raw audio that is skipped as non-speech or discarded during overload.

#### Scenario: Meeting contains skipped or discarded audio
- **GIVEN** one or more audio windows were ignored as non-speech or discarded during overload
- **WHEN** the meeting is stopped
- **THEN** no application-managed raw audio for those windows remains in durable storage
