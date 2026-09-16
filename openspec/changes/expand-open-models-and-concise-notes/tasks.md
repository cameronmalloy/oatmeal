## 1. Expand permissively licensed model choices

- [x] 1.1 Add catalog tests for the intended Whisper and generation model identifiers, direct HTTPS files, model kinds, and removal of Qwen 2.5 3B; verify `swift test --filter ModelProvisioningTests` fails against the current catalog.
- [x] 1.2 Add the curated Whisper, Granite, and non-thinking Qwen descriptors using exact artifact sizes and license-disclosing source labels; verify `swift test --filter ModelProvisioningTests` passes.

## 2. Generate concise action-oriented notes

- [x] 2.1 Add prompt and validator tests for Action Items, Decisions, Meeting Summary order, missing-owner/date placeholders, one bullet per started 30-minute interval, and the new prompt version; verify `swift test --filter NoteGenerationTests` exposes the current behavior.
- [x] 2.2 Replace the shared prompt contract and required headings, and raise the generation context budget to 32,768 tokens; verify `swift test --filter NoteGenerationTests` passes.

## 3. Regression verification

- [x] 3.1 Run `swift test` and verify all core tests pass with no meeting source-data mutation or network dependency during inference tests.
- [x] 3.2 Run `Tests/release-smoke.sh` and verify the release smoke test passes with the expanded download catalog and new prompt contract.
