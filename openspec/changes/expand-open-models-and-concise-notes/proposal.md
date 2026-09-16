## Why

Oatmeal currently offers only two transcription models and two note-generation models, including a Qwen 3B model whose research license does not permit unrestricted commercial use. Its generated notes are also longer and less action-oriented than needed for quickly reviewing a meeting.

## What Changes

- Expand the curated Whisper catalog with permissively licensed speed, language, and quality tiers that remain compatible with the existing whisper.cpp runtime.
- Restrict the note-model catalog to single-file GGUF models hosted on Hugging Face under MIT or Apache 2.0 terms and compatible with the existing llama.cpp runtime.
- Remove the noncommercial Qwen 2.5 3B model from the downloadable catalog and add Granite 3.3 plus a non-thinking Apache-licensed Qwen option.
- Replace the generated-note format with Action Items first, Decisions second, and a concise Meeting Summary last.
- Require explicit `Unassigned` and `No due date stated` placeholders rather than inferred owners or dates.
- Produce one short summary bullet for each started 30-minute meeting interval and increase the single-pass context budget for the expected 60–120-minute meeting duration.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `local-transcription` — expands the curated permissively licensed Whisper choices.
- `note-generation` — restricts downloadable models to permissive licenses and changes the generated-note structure, grounding placeholders, and length contract.

## Impact

- Updates the static model catalogs and their provisioning tests.
- Updates the shared generation prompt, prompt version, output validator, context budget, and focused generation tests.
- Does not add an inference backend, dependency, stored-data migration, cloud service, or model-specific prompt framework.
