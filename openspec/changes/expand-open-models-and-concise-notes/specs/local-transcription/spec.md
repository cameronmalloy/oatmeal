## Purpose

Expand local transcription choices without changing Oatmeal's offline inference or privacy boundary.

## MODIFIED Requirements

### Requirement: In-app transcription-model provisioning

The system SHALL let the user download and select a supported transcription model in the application without requiring Terminal or manual file placement. The curated catalog SHALL include permissively licensed English-only and multilingual models spanning speed and quality tiers that are compatible with the bundled local runtime.

#### Scenario: Provision a model during onboarding

- **GIVEN** no compatible transcription model is installed
- **WHEN** the user opens model setup
- **THEN** the system presents a curated model list with name, download size, language scope, speed/quality guidance, license, and source
- **AND** the user can download a model with visible progress and a Cancel action
- **AND** a successful download is stored in the application's Application Support directory and selected for transcription

#### Scenario: Choose a transcription trade-off

- **GIVEN** the user opens transcription model setup
- **WHEN** the curated list is displayed
- **THEN** the list includes a fast compact English option
- **AND** a multilingual option
- **AND** a higher-quality option
- **AND** every listed model is compatible with whisper.cpp and licensed for unrestricted commercial use

#### Scenario: Insufficient disk space

- **GIVEN** the Mac lacks enough free space for the selected model and a safety margin
- **WHEN** the user attempts to download it
- **THEN** the system does not start the download
- **AND** the system displays an actionable storage error
