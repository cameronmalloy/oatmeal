## Purpose

Generate short, action-oriented meeting notes with permissively licensed local models while preserving explicit grounding in meeting source material.

## MODIFIED Requirements

### Requirement: Structured meeting-note output

Generated notes SHALL contain exactly three top-level sections in this order: Action Items, Decisions, and Meeting Summary.

#### Scenario: Successful generation

- **GIVEN** a meeting contains a transcript
- **WHEN** note generation completes successfully
- **THEN** the generated document begins with Action Items
- **AND** Decisions follows Action Items
- **AND** Meeting Summary follows Decisions
- **AND** Action Items or Decisions with no supported content explicitly state `None identified.` rather than fabricating content

### Requirement: Ground generation in meeting source material

The system SHALL generate notes from the persisted transcript and user-authored notes for the selected meeting and SHALL instruct the model not to invent unsupported facts, owners, dates, action items, or decisions.

#### Scenario: Action item has an owner and due date

- **GIVEN** the meeting source explicitly assigns an action to a named person and states a due date
- **WHEN** notes are generated
- **THEN** the action-item bullet includes that owner, due date, and action

#### Scenario: Action item has no owner or due date

- **GIVEN** the meeting source contains an action item without an explicit owner or due date
- **WHEN** notes are generated
- **THEN** the action item uses `Unassigned` as its owner
- **AND** uses `No due date stated` as its due date
- **AND** does not infer either value

#### Scenario: User note highlights context

- **GIVEN** the user wrote a note marking a topic as important
- **WHEN** notes are generated
- **THEN** that note is available to the local model as source context distinct from transcript text

### Requirement: Concise time-proportional meeting summary

The Meeting Summary SHALL contain exactly one bullet for each started 30-minute interval of the meeting. Each bullet SHALL be one concise paragraph of no more than three sentences and SHALL describe only its corresponding interval.

#### Scenario: Meeting lasts less than 30 minutes

- **GIVEN** a meeting has transcript content before minute 30
- **WHEN** notes are generated
- **THEN** Meeting Summary contains one interval bullet

#### Scenario: Meeting crosses a 30-minute boundary

- **GIVEN** a meeting has transcript content before and after minute 30
- **WHEN** notes are generated
- **THEN** Meeting Summary contains separate bullets for `00:00–30:00` and `30:00–60:00`

#### Scenario: Meeting crosses multiple boundaries

- **GIVEN** a meeting has transcript content in three started 30-minute intervals
- **WHEN** notes are generated
- **THEN** Meeting Summary contains exactly three chronologically ordered interval bullets

### Requirement: Configurable local model

The system SHALL allow note generation to use a locally available compatible model selected through application configuration rather than requiring one hard-coded model artifact. Every model offered for in-app download SHALL use a permissive MIT or Apache 2.0 license and a single-file GGUF artifact compatible with llama.cpp.

#### Scenario: Change local model

- **GIVEN** two compatible local language models are available
- **WHEN** the user selects a different model before regenerating notes
- **THEN** the next generation uses the newly selected local model
- **AND** existing transcript and user-note source data remain unchanged

#### Scenario: First generation without a model

- **GIVEN** no compatible note-generation model is installed
- **WHEN** the user first requests generated notes
- **THEN** the system presents supported local models with name, download size, performance guidance, license, and source
- **AND** the user can download a model with visible progress and a Cancel action
- **AND** generation remains unavailable until a compatible model is successfully installed and selected

#### Scenario: Restricted model is excluded

- **GIVEN** a model uses a research-only, noncommercial, gated, or custom community license
- **WHEN** the downloadable note-model catalog is assembled
- **THEN** that model is not offered for download
