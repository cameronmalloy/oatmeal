## Purpose

Maintain a durable, chronologically ordered record of the meeting conversation while distinguishing the user's speech from all other captured participants without requiring named-speaker diarization.

## ADDED Requirements

### Requirement: Two-party-class transcript labeling

The transcript SHALL label microphone-originated speech as `Me` and system-audio-originated speech as `Others`.

#### Scenario: Display mixed conversation
- **GIVEN** finalized transcript segments exist from both microphone and system audio
- **WHEN** the user views the meeting transcript
- **THEN** microphone segments are displayed as `Me`
- **AND** system-audio segments are displayed as `Others`

### Requirement: Chronological transcript presentation

The transcript SHALL present finalized segments in meeting-time order regardless of the order in which transcription inference completed.

#### Scenario: Late-arriving earlier segment
- **GIVEN** a transcript already displays a later timestamped segment
- **WHEN** an earlier timestamped segment is finalized afterward
- **THEN** the transcript places the earlier segment before the later segment

### Requirement: Durable finalized transcript

Finalized transcript segments SHALL be persisted locally during the meeting rather than only at meeting completion.

#### Scenario: Application terminates after partial meeting
- **GIVEN** finalized transcript segments have been produced and persisted
- **WHEN** the application terminates before the meeting is intentionally stopped
- **THEN** the persisted finalized transcript segments remain available when the application is reopened

### Requirement: Transcript availability after meeting

The full persisted transcript SHALL remain viewable after capture stops and after generated notes are created.

#### Scenario: Reopen completed meeting
- **GIVEN** a meeting has ended with a persisted transcript
- **WHEN** the user opens that meeting from history
- **THEN** the transcript is available independently of whether generated notes exist

### Requirement: Transcript integrity during note generation

Generating or regenerating meeting notes MUST NOT alter the persisted transcript.

#### Scenario: Regenerate notes
- **GIVEN** a meeting contains a persisted transcript
- **WHEN** the user regenerates the meeting notes with a different local LLM configuration
- **THEN** the persisted transcript content remains unchanged
