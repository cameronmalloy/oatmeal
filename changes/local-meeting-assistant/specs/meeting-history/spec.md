## Purpose

Provide a local archive of captured meetings so users can reopen source material and generated notes, identify meetings by a useful title, regenerate outputs, and intentionally delete stored data.

## ADDED Requirements

### Requirement: Persist completed meetings locally

The system SHALL retain completed meeting records locally until the user deletes them.

#### Scenario: Reopen application
- **GIVEN** one or more completed meetings are stored locally
- **WHEN** the application is closed and later reopened
- **THEN** the stored meetings remain available in meeting history

### Requirement: Meeting history listing

The system SHALL present locally stored meetings with enough metadata to distinguish them, including at minimum a title and meeting date/time.

#### Scenario: Multiple meetings exist
- **GIVEN** multiple completed meetings are stored
- **WHEN** the user opens meeting history
- **THEN** each meeting can be identified by its displayed title and date/time

### Requirement: User can rename a meeting

The system SHALL allow the user to change the display title of a stored meeting without altering its transcript or notes.

#### Scenario: Rename completed meeting
- **GIVEN** a stored meeting exists
- **WHEN** the user changes its title
- **THEN** the new title is shown in meeting history
- **AND** transcript, user notes, and generated notes remain unchanged

### Requirement: User can reopen stored meeting content

The system SHALL allow a meeting selected from history to expose its persisted transcript, user notes, and latest successful generated notes.

#### Scenario: Open historical meeting
- **GIVEN** a stored meeting has transcript, user notes, and generated notes
- **WHEN** the user selects the meeting from history
- **THEN** those stored artifacts are available for viewing
- **AND** the meeting can be used as source material for regeneration

### Requirement: User can delete a stored meeting

The system SHALL allow the user to intentionally delete a meeting and its locally persisted artifacts.

#### Scenario: Delete completed meeting
- **GIVEN** a stored meeting exists
- **WHEN** the user confirms deletion
- **THEN** the meeting is removed from meeting history
- **AND** its persisted transcript, user notes, and generated-note records are removed from application storage
