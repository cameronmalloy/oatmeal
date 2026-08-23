## Purpose

Let the user capture lightweight thoughts and emphasis during a live meeting so local note generation can incorporate what the user considered important without requiring structured note-taking.

## ADDED Requirements

### Requirement: User can write notes during capture

The system SHALL allow the user to create and edit free-form text notes while a meeting is active without stopping audio capture or transcription.

#### Scenario: Add a note during conversation
- **GIVEN** a meeting is actively capturing and transcribing
- **WHEN** the user types a note
- **THEN** capture and transcription continue
- **AND** the note is associated with the active meeting

### Requirement: Notes preserve meeting timing

Each user note SHALL preserve enough timing information to establish when it was created relative to the meeting timeline.

#### Scenario: Two notes are created at different times
- **GIVEN** the user creates one note early in the meeting and another later
- **WHEN** the meeting is reopened
- **THEN** the notes retain their original chronological relationship

### Requirement: Notes persist independently of generated output

User-authored notes SHALL be stored as source material and MUST NOT be overwritten when generated meeting notes are created or regenerated.

#### Scenario: Regenerate meeting summary
- **GIVEN** the user has written notes during a meeting
- **WHEN** generated notes are regenerated
- **THEN** the original user-authored notes remain unchanged

### Requirement: User notes influence note generation

The note-generation capability SHALL receive user-authored notes as distinct source material in addition to the transcript.

#### Scenario: User flags a topic not emphasized by transcript length
- **GIVEN** the user has written a brief note identifying a topic as important
- **WHEN** the system generates post-meeting notes
- **THEN** the generation input includes that user note separately from the transcript
