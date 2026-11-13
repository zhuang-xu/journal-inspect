> Historical snapshot through 2026-11-05. Superseded by the [current documentation](../README.md). These claims describe earlier stages and are not current product instructions.

# Personal memory, retrieval quality, and historical coverage

Date: 2026-11-05

Status: M1 full-build pipeline implemented; broad extraction quality remains unvalidated; later milestones proposed

Application: Journal Inspect for macOS

## Outcome

Build a local journal assistant that knows useful background, finds relevant original evidence, and can answer questions about changes over time without loading the entire history into every prompt.

The three parts have different responsibilities:

| Part | Responsibility |
| --- | --- |
| Personal memory | Compact, dated background: circumstances, goals, relationships, preferences |
| Passage retrieval | Specific evidence relevant to the current question |
| Historical coverage | Dated summaries and deliberate coverage for patterns and comparisons |

Keep the Swift architecture small. Reuse JournalCore, JournalEmbeddings, JournalGeneration, the on-demand reader, and existing prompt interfaces. Implement in milestones. The personal-memory implementation now adds optional private derived persistence; see PERSONAL_MEMORY.md for shipped behavior and remaining evaluation limits.

## Current baseline

The app reads Apple Journal through a read-only SQLite connection. Its persistent index contains metadata and keyed fingerprints, not bodies or titles. Current semantic retrieval reads synced entries in pages, splits current bodies into passages of at most 768 UTF-8 bytes, embeds them locally, and ranks them against the question. Embeddings are recomputed on each context preparation.

The retriever selects one passage per entry from a 25-entry semantic candidate pool by default; the prompt builder and answer tokenizer then bound the final selected evidence. There is no calibrated relevance cutoff, retained vector cache, personal memory, date interpretation, or historical coverage policy. The context builder budgets serialized JSON bytes; it does not measure the total model request in tokens.

The answer engine currently configures an 8,192-token context and reserves up to 768 output tokens. It clears native context between answers. Qwen3-0.6B is a functional local baseline with documented quality weaknesses. Existing synthetic tests establish pipeline behavior, not general extraction or answer reliability.

## Design rules

- Preserve original entry identity and source references through every derived artifact.
- Keep model-proposed interpretations distinguishable from user corrections and original evidence.
- Bound prompt size independently of journal size. More stored information must not mean an ever-growing prompt.
- Update derived data incrementally and invalidate it when supporting sources change or disappear.
- Keep original Journal access read-only. Do not log journal text, extracted facts, prompts, or vectors.
- Treat summaries and memories as fallible, dated data, never as model instructions.
- Report unavailable evidence and incomplete coverage instead of implying an exhaustive search.

## 1. Personal memory

### Content

Store short statements likely to help across conversations: current circumstances, ongoing goals, important relationships, and explicitly expressed preferences. Keep a meaningful as-of date.

Example: “As of October 28, preparing for backend engineering interviews.”

A single account of nervousness must not become a permanent personality judgment. One-off events belong in searchable evidence. Inferred recurring patterns belong in historical analysis and require supporting examples.

### Minimal record

| Field | Purpose |
| --- | --- |
| ID | Stable identity for edits and source links |
| Statement and category | Readable background fact |
| As-of date | Time at which the statement was supported; distinguish journal date from processing date |
| Source references | Source ID, entry UUID, fingerprint/content revision, and relevant passage locator |
| Origin | Automatic extraction or user-authored/corrected |
| State | Active, outdated, or awaiting clarification |
| Processing version | Extraction model and prompt version for reproducible rebuilds |

A memory may have multiple supporting entries. Source references are stored separately from its concise statement and need not all appear in the prompt.

### Update flow

1. On initial setup, process history in bounded, cancellable batches.
2. After a successful sync, identify new/changed entries and deleted sources from metadata. Do not rely only on the aggregate changed count.
3. Read affected current bodies and ask the local generation model for structured candidate facts tied to supplied sources.
4. Validate the output schema, sizes and source references. Structure validation does not prove a fact is true; evaluate extraction quality separately.
5. Merge duplicates and add supporting sources. Preserve dates and user corrections. Ambiguous conflicts become proposed changes for review.
6. Commit validated updates atomically and record processed revisions. Interrupted work must be resumable without duplicate facts.

Reprocessing an edited entry replaces its old extracted contributions. When support disappears, reevaluate a fact against remaining sources; exclude unsupported automatic facts. User-authored statements retain their own origin. A newer processing timestamp alone must not override an older real-world fact.

Forgetting a suggestion should prevent the same unchanged source from recreating it. Store a minimal local suppression record, with explicit restore/reset behavior. Clear suppression records when the user chooses Delete all memory; explain that a later explicit rebuild may recreate suggestions.

### Consolidation and budget

Start with a target profile budget of 600–1,000 actual answer-model tokens, subject to evaluation and total request capacity. This is a design target, not an established optimum.

Merge repetitions, shorten wording, and move outdated facts out of the active profile. Do not rewrite the entire memory from its previous summary repeatedly: rebuild consolidated statements from source-linked facts so errors do not compound unchecked. Preserve user corrections during consolidation.

Separate stored memories from the bounded active profile. Older facts remain available for targeted lookup. Show when the profile budget excludes active facts; do not silently discard user-authored information to satisfy a limit.

### User controls

Provide a Memory view with enable/disable, statement, date, source navigation, edit, forget, rebuild, and delete-all actions. User edits take precedence over automatic rewrites. Disabling memory excludes it from prompts and stops automatic memory updates. Reenabling catches up from source revisions.

## 2. Retrieval quality

### Cache embeddings first

Retain passage vectors in a session cache, then add a persistent cache using the same record format if startup measurements justify it. Store entry/source identity, source revision, passage boundaries, vector dimensions, model checksum, decoder version, and chunking version. Do not retain full passage bodies solely for the vector cache; reopen originals for answer evidence.

After sync, reuse unchanged vectors, replace affected entry vectors, and remove deleted ones. Model or chunking changes invalidate the corresponding cache. Publish a replacement only after its entry has been fully processed; partial caches must be identified as incomplete.

The source can change between sync and reading. Cache validity must correspond to the text actually embedded, not just a previously indexed fingerprint. Reopen selected originals and validate their revision before use; refresh stale candidates and refill results where possible. Never use a deleted entry merely because its vector remains cached.

Use an exhaustive in-memory vector scan initially. Add a specialized vector database only if measured scale requires it.

### Improve passages and selection

- Split at paragraph/sentence boundaries where possible and add measured overlap, while enforcing the embedding model's actual input limit.
- Retrieve a larger candidate pool, initially around 20–30 passages as an evaluation setting.
- Remove overlapping duplicates and balance relevance with diversity. Allow several useful passages from one entry.
- Select final evidence against an actual token budget instead of targeting five entries. Keep a bounded candidate count and execution budget.
- Evaluate relevance cutoffs on labeled examples. Cosine scores are not probabilities; a universal arbitrary cutoff is not sufficient.
- Return insufficient-evidence results when appropriate. Do not fill the prompt merely to reach a count.

A reranker is a later addition if candidate recall is good but final ordering remains weak. AI-extracted entities/topics may improve exact-name matching later; they are optional and do not replace original-text embeddings.

Keep the original question as the search input initially. Memory-assisted query rewriting comes later and must preserve the original query as one search path, avoiding profile-driven bias.

## 3. Historical coverage

### Build dated summaries

Start with monthly summaries; add weekly granularity only if examples show a need. Process original entries in bounded batches, preserve supporting entry IDs, and combine findings with dates intact. Monthly summaries must not depend solely on the personal profile or retrieved nearest passages.

Each summary records its period, processed source revisions, relevant events/themes, source references, processing version, and completeness. Missing, failed, empty, and genuinely quiet periods are different states. Changed or deleted entries invalidate affected periods and any higher-level synthesis that depends on them.

Summaries are a navigation/compression layer. For specific factual claims, retrieve and validate original supporting passages. Preserve contradictory experiences rather than smoothing them into a single narrative.

### Use question scope explicitly

| Question | Evidence strategy |
| --- | --- |
| “What happened with Alex?” | Relevant original passages; clarify identity if ambiguous |
| “What happened last month?” | Explicit local-calendar window and that period's sources/summary |
| “How has work anxiety changed this year?” | Summaries across the requested period plus original evidence from multiple periods |
| “Compare before and after changing jobs.” | Establish the event/date, then use separate windows; ask if the boundary is unknown |

Implement explicit date/scope controls before model-based routing. No date in a narrow topic question means search all indexed history, without automatic recency restriction. A broad question needs a coverage strategy, not simply more nearest neighbors.

For trend answers, include requested period, available period, processed periods/entries, gaps, and examples supporting both continuity and change. Distinguish occurrence in the journal from real-world frequency: writing more about anxiety does not alone prove anxiety increased.

A bounded batch-analysis mode can cover selected history when summaries are missing. Show progress and allow cancellation. If execution limits prevent completion, disclose partial coverage rather than silently falling back to a few excerpts.

## Prompt integration

Build each answer request from:

1. Instructions about evidence, dates, citations, uncertainty, and untrusted content.
2. The bounded personal profile, when enabled.
3. Relevant period summaries for broad questions.
4. Current original excerpts with source citations.
5. The original user question.

Measure the fully formatted prompt with the answer model's tokenizer. Reserve output capacity first, then account for instructions and question before assigning memory, summary, and excerpt budgets. Never assume a JSON byte budget alone proves that the complete request fits.

Memory supplies background; summaries describe periods; originals substantiate details. Keep these roles identifiable in the prompt and UI. Profile use must not cause unrelated retrieved evidence to be interpreted as support for a remembered claim.

## Swift architecture and storage

Keep orchestration in the existing modules:

- JournalCore: memory/summary records, private derived-data storage, source tracking, consolidation rules, and retrieval/coverage planning.
- JournalEmbeddings: existing native embedding actor behind JournalTextEmbedding.
- JournalGeneration: model-backed extraction and summarization alongside existing generation, with validated structured outputs.
- App: update coordination, progress/cancellation, Memory controls, and evidence/coverage presentation.

Start with concrete PersonalMemoryStore and PersonalMemoryUpdater responsibilities; reuse RetrievalPlanning, JournalRetrieving, and the existing context flow. Introduce additional abstractions only when implementations need them. Keep model execution off the main actor and serialize native runtime ownership as today.

Use one new private derived-data store outside the existing metadata index for memories, source links, and later vectors/summaries. Keep the original metadata index metadata-only. Persistent facts, summaries and vectors are sensitive content-derived data; adding them is an explicit product behavior change. Apply private file permissions and exclude them from diagnostic output. Do not claim file permissions provide application-level encryption.

Deleting/rebuilding derived data must leave original Journal content intact. Memory and vector/summary reset controls should describe which derived artifacts they remove.

## Milestones and acceptance criteria

| Milestone | Deliverables | Exit criteria |
| --- | --- | --- |
| M0: Evaluation baseline | Synthetic journal corpus and labeled questions covering Chinese/English, names, old events, missing evidence, conflicts and time comparisons | Record current retrieval accuracy, answer grounding, token usage and latency; define expected supporting sources |
| M1: Personal memory | Structured extraction, source-linked storage, incremental updates, consolidation, editable profile and prompt integration | Repeated facts deduplicate; corrections survive updates/rebuilds; edited/deleted support is handled; profile stays within budget; disabled memory is absent from prompts |
| M2: Cached retrieval | Session cache, revision validation, incremental invalidation; optional persistent cache after measurement | Repeated unchanged searches perform zero document re-embeddings; query embedding remains expected; edits/deletions cannot reuse stale evidence; cancellation leaves valid cache state |
| M3: Evidence selection | Improved passages, larger candidate pool, diverse budgeted selection and insufficient-evidence handling | Labeled retrieval improves over baseline; long entries can contribute multiple passages; unrelated questions are not forced to return five results; total prompts fit |
| M4: Historical coverage | Monthly summaries, explicit scope, comparison windows, batch fallback and coverage display | Trend/comparison fixtures use relevant periods, cite original evidence, identify gaps, and update after source changes |
| M5: Integrated validation | End-to-end UI checks and representative local-model evaluations | Memory/evidence/coverage agree; measured latency and memory are documented; signed normal app product contains the tested implementation |

Run appropriate synthetic tests at each milestone and opt-in native-model checks for extraction, retrieval and summary quality. Before real-history backfill, use M0 examples to determine whether the current small local model is adequate for extraction and summarization. A well-formed JSON response alone is not an acceptance criterion for correctness.

Measure supporting-source recall, irrelevant evidence selection, unsupported memory claims, citation correctness, temporal coverage, and warm/cold latency. Set numerical quality targets from the baseline before declaring a milestone complete. Diagnostics should contain only aggregate measurements, never private statements or text.

## Deferred work

Autonomous repeated searches, relationship graphs, proactive coaching, attachments, cloud inference, and fine-tuning are outside these milestones. The immediate sequence is personal memory, cached and better-selected evidence, then historical coverage. Product claims should match the measured coverage and model quality at each stage.
