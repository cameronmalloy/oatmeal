## Context

Oatmeal already provisions models from two static `ModelCatalog` arrays. Whisper GGML files use the existing whisper.cpp process adapter, and note-generation GGUF files use the existing llama.cpp process adapter. Adding compatible single-file artifacts therefore requires catalog data rather than a new runtime abstraction.

The shared note prompt currently requests five sections and budgets 8,192 context tokens. It trims a transcript to that budget and validates only that every requested heading exists. The product target is a 60–120-minute meeting, while the desired output is substantially shorter: action items, decisions, and one short summary bullet per started 30-minute interval.

## Goals / Non-Goals

**Goals:**

- Offer useful Whisper speed, English-only, multilingual, and higher-quality tiers.
- Offer compact and higher-quality note models whose weights may be used commercially and for any other purpose allowed by MIT or Apache 2.0.
- Keep every model compatible with the existing local process adapters and one-file downloader.
- Make generated notes short, consistently ordered, and grounded in explicit meeting evidence.
- Cover the expected meeting duration in one local generation pass.

**Non-Goals:**

- Meta Llama or any model with a custom, research-only, noncommercial, gated, or attribution-specific model license.
- Arbitrary Hugging Face browsing, user-entered download URLs, split GGUF downloads, or a model registry service.
- Multi-pass or map/reduce summarization for meetings beyond the expected 120-minute duration.
- Model-specific sampling profiles or prompt templates.

## Decisions

### 1. Extend the existing static catalogs with permissive single-file artifacts

Keep the current Whisper Base English and Small English choices and add:

- Whisper Tiny English for the fastest, lowest-memory English tier;
- Whisper Base multilingual for a compact multilingual tier;
- Whisper Medium English Q5 for a higher-capacity quantized English tier;
- Whisper Large v3 Turbo Q5 for the strongest curated multilingual tier.

Keep Qwen 2.5 1.5B Instruct Q4_K_M and replace the research-licensed Qwen 2.5 3B entry with:

- Granite 3.3 2B Instruct Q4_K_M as the compact summarization-oriented tier;
- Qwen3 4B Instruct 2507 Q8_0 as a non-thinking, Apache-licensed middle tier;
- Granite 3.3 8B Instruct Q4_K_M as the higher-quality tier for Macs with at least 16 GB memory.

All artifacts remain direct HTTPS downloads from Hugging Face repositories maintained by the upstream model organization or ggml-org. The UI will disclose the license in the existing source label, avoiding a new descriptor field and view.

Qwen 2.5 7B is not selected because its upstream Q4_K_M artifact is split while the existing downloader installs one file. The original hybrid Qwen3 4B is not selected because reliable concise output requires thinking-mode and sampling configuration that the shared runtime does not expose.

### 2. Use one shared concise note contract for every generation model

Increment the prompt version and require exactly these top-level headings in this order:

```markdown
# Action Items
- **Owner:** Name or Unassigned | **Due:** Date or No due date stated | Action

# Decisions
- A decision supported by the meeting source

# Meeting Summary
- **00:00–30:00:** A concise paragraph of no more than three sentences.
```

Action items and decisions use `- None identified.` when the source contains none. Owners and due dates must be copied from the source when explicit; otherwise the fixed placeholders are required. This makes absence visible without inviting the model to infer details.

The summary contains exactly one bullet for each started 30-minute interval. A meeting under 30 minutes receives one bullet; a 60-minute meeting receives two; a meeting extending beyond 60 minutes receives another bullet for the started interval. Each bullet is one paragraph of at most three sentences.

### 3. Raise the shared single-pass context budget to 32K

Use a 32,768-token context for note generation. This is supported by every curated generation model and is sufficient for the product's expected 60–120-minute meeting duration in typical transcripts while retaining the current simple, local, single-pass flow.

Multi-pass summarization is deferred. If real 120-minute transcripts regularly exceed the 32K input budget or omission is observed, introduce chunked extraction and final synthesis as a separate change rather than embedding speculative orchestration now.

### 4. Validate the externally visible format, not model-specific prose

Update `GeneratedNoteValidator` to require the three new headings. Prompt tests will assert order, placeholders, interval instructions, and grounding language. Validator tests will reject missing sections while allowing model-specific wording within each section.

## Risks / Trade-offs

- **Large models can be slow or memory-heavy** → Keep explicit size/hardware guidance and retain compact options.
- **A model can ignore the requested length** → Enforce headings deterministically and make the concise limit explicit; avoid brittle prose-length rejection that could discard otherwise useful notes.
- **Very long meetings can exceed one-pass context** → Cover the expected 60–120-minute duration at 32K and defer multi-pass generation until measured need.
- **Upstream artifacts can change at mutable URLs** → Continue size and format validation in this change; checksum pinning can be added separately if catalog supply-chain hardening is required.

## Migration Plan

No stored-data migration is required. Existing generated notes retain their recorded prompt version and content. New generations use the new prompt version and format. Removing Qwen 2.5 3B from the downloadable catalog does not delete an already-downloaded user file or rewrite an existing model configuration.
