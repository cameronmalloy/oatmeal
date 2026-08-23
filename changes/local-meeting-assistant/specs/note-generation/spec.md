## Purpose

Transform the persisted transcript and the user's own meeting notes into structured, useful post-meeting notes using a configurable local language model without changing the underlying source material.

## ADDED Requirements

### Requirement: Local-only note generation

The system SHALL generate meeting notes with an on-device language-model runtime and MUST NOT require a cloud inference service.

#### Scenario: Generate notes offline
- **GIVEN** a compatible local language model is configured
- **AND** a meeting contains sufficient transcript content
- **AND** the Mac has no network connectivity
- **WHEN** the user generates meeting notes
- **THEN** the system can produce notes locally

### Requirement: Structured meeting-note output

Generated notes SHALL include distinct sections for Summary, Decisions, Action Items, Open Questions, and Important Context.

#### Scenario: Successful generation
- **GIVEN** a meeting contains a transcript
- **WHEN** note generation completes successfully
- **THEN** the generated document contains the required sections
- **AND** sections with no supported content remain empty or explicitly indicate that none was identified rather than fabricating content

### Requirement: Ground generation in meeting source material

The system SHALL generate notes from the persisted transcript and user-authored notes for the selected meeting and SHALL instruct the model not to invent unsupported facts, owners, dates, or decisions.

#### Scenario: No due date was mentioned
- **GIVEN** the transcript contains an action item but no due date
- **WHEN** notes are generated
- **THEN** the generated action item does not invent a due date

#### Scenario: User note highlights context
- **GIVEN** the user wrote a note marking a topic as important
- **WHEN** notes are generated
- **THEN** that note is available to the local model as source context distinct from transcript text

### Requirement: Regenerable notes

The user SHALL be able to regenerate notes for an existing meeting without re-capturing or re-transcribing the meeting.

#### Scenario: Regenerate from stored source material
- **GIVEN** a completed meeting has a persisted transcript and user notes
- **WHEN** the user requests regeneration
- **THEN** the system generates a new result from the stored source material
- **AND** the persisted transcript and user notes are not modified

### Requirement: Configurable local model

The system SHALL allow note generation to use a locally available compatible model selected through application configuration rather than requiring one hard-coded model artifact.

#### Scenario: Change local model
- **GIVEN** two compatible local language models are available
- **WHEN** the user selects a different model before regenerating notes
- **THEN** the next generation uses the newly selected local model
- **AND** existing transcript and user-note source data remain unchanged

### Requirement: Recoverable generation failure

A note-generation failure MUST NOT delete or corrupt the meeting transcript, user notes, or the last successfully generated notes.

#### Scenario: Local model fails during regeneration
- **GIVEN** a meeting has source material and a previously successful generated note
- **WHEN** regeneration fails
- **THEN** the source material remains available
- **AND** the previous successful generated note remains available
- **AND** the user can retry generation
