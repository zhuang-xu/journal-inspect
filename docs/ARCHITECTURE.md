# Current Swift architecture

Source-checked: 2026-11-06. This describes implemented code. See [cache operation and validation](EMBEDDING_CACHE.md) and the original [cache design](plans/SQLITE_EMBEDDING_CACHE_DESIGN.md).

## Modules and ownership

| Module | Current responsibility |
| --- | --- |
| `JournalCore/Data` | Read-only Apple Journal access, metadata synchronization, SQLite wrapper, on-demand bodies |
| `JournalCore/Memory` | Private memory persistence, source tracking, incremental/full extraction orchestration, profile selection |
| `JournalCore/Prompt` | Retrieval contracts, context budgeting, prompt augmentation and answer presentation |
| `JournalCore/Retrieval` | Transient/cached semantic retrieval, passage splitting, vector validation, embedding-space identity, SQLite vector cache and incremental updater |
| `JournalEmbeddings` | Actor-owned local embedding model, native tokenization, normalized vectors |
| `JournalGeneration` | Pinned generation-model registry, verification, chat formatting, token-budget checks and streamed answers |
| `JournalLlama` | Shared native backend initialization and diagnostic suppression |
| `App` | Composition root, retrieval application service, SwiftUI Reflect and Entries navigation, settings, task lifecycle, progress, source review and model selection |

Core does not depend on llama.cpp. Python is used by model-download setup tooling, not by the application runtime or Journal decoder.

## Application and infrastructure boundaries

`JournalAppComposition` assembles each window's feature models and explicitly shares one `PersonalMemoryStore` and `JournalEmbeddingCache`. The main window opens on Reflect, with Entries as the other destination. Manual maintenance, model choice, and saved background controls live in Journal Settings. `ReaderViewModel` coordinates the window and sync; feature models no longer construct sibling models or each other's stores. `PromptViewModel` owns user-visible request identity, progress, preview and streamed-answer state. `JournalPromptService` owns retrieval preparation, source freshness and embedding-model lifetime for cached/transient search and cache updates. Every embedding operation unloads its native resources on success and failure. Generation remains actor-owned in `LocalAnswerModel`, with presentation updates in the prompt view model.

Blocking Core scans and memory source reads use `journalWorker`: the caller's cancellation is forwarded to a detached worker, with checks before work and before a result is returned. Database handles are created and consumed inside the worker. Reader browsing/sync tasks retain explicit worker handles because the window directly controls their cancellation and request identity.

`PrivateStoreFile` applies the same 0700 directory / 0600 regular-file policy before any store opens SQLite. It rejects directory/file symlinks and repairs permissions on existing store files. Schema validation, transactions, journaling and error translation remain owned by each store. `EmbeddingVector` provides shared finite/nonzero vector normalization without coupling cache serialization to a concrete retriever.

Context construction retains an evidence reference only when its exact excerpt is selected. Deduplicating source identities cannot accidentally retain references from discarded passages. These references remain host-side.

See the [architecture cleanup review](ARCHITECTURE_REVIEW.md) for scope and verification.

## Source reading and metadata

Default source: `~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite`.

`JournalReader` opens SQLite with read-only access and validates the private schema. Synchronization uses a consistent source read transaction, streams entry/asset metadata and computes keyed fingerprints. TEMP asset ordering contains numeric keys; attachment files are not opened. A separate metadata transaction commits a complete scan and reconciles missing entries. Cancellation/failure rolls back incomplete changes; it must not authorize deletion reconciliation.

The source is not copied or exported, opened as immutable, migrated, indexed or explicitly checkpointed by this app. Normal SQLite WAL/SHM coordination can still occur, and a long read can delay checkpoint progress. Read-only access is not a promise that every supporting file is byte-for-byte untouched.

Index: `~/Library/Application Support/JournalInspect/journal-index.sqlite3`. It stores source/entry UUIDs, source dates, keyed fingerprints, deletion state and sync history—not bodies, titles, attachment files, vectors or memory statements. Source dates use Apple's 2001 reference epoch; run/observation timestamps use Unix time. The default cooperative source-read budget is 60 seconds; busy waits and individual operations can delay cancellation.

`JournalMetadataStore.browse` provides 50-entry UI pages and optional inclusive-start/exclusive-end date filters. Selecting an entry reopens its current body, checks identity/deletion and decodes RTF natively. Each on-demand read is consistent, but a multi-entry search is not one atomic source snapshot. Apple schema changes and macOS permissions remain external limitations.

## Question-to-answer flow

The detailed [prompt and output design](PROMPT_AND_OUTPUT_DESIGN.md) includes the draft/final distinction, model-facing template, token-fitting rules and streaming contract.

1. The retrieval workflow verifies the actual local embedding weights and loads the model, exposing the document-space descriptor and actual output dimension.
2. `JournalQueryPlanner` requests up to 25 candidates, without inferring a date window.
3. `CachedJournalRetriever` synchronizes source metadata, captures a source-scoped immutable manifest and updates only missing/changed entries. Compatible vectors survive restarts. It streams vector rows, retaining the best passage per entry, and reopens selected originals to validate body revisions, dates and UTF-8 locations. Disabling the cache uses `SemanticJournalRetriever` after the same freshness scan and retains equivalent in-memory original references without reading cache storage. Both modes use the same bounded expansion and emit exact references for the resulting excerpts.
4. `BudgetedContextBuilder` deduplicates source identities and keeps whole ranked excerpts within 4,096 serialized UTF-8 bytes by default. An oversized candidate is skipped; the following candidates can still fit.
5. `PersonalMemoryStore.profile(for:embeddings:...)` ranks enabled, supported memory statements by question cosine similarity, rejecting scores below the development operating point 0.5. Exact-score ties use origin, confirmation, recency and UUID. Exact duplicates are removed, conflicts retained. No initial byte cap precedes final token fitting. Statement vectors reuse a separate namespace in the existing cache.
6. **Ask Journal** normally prepares fresh excerpts and background before loading the answer model. If the user reviewed a draft separately, its excerpts are reused only if they still validate, and the background is selected again. Embedding resources unload before answer weights are verified and loaded. A store-revision and selected-source check after loading rejects concurrent changes. Context/token budgeting filters references along with excerpts. The fitted references are revalidated before inference and never enter model input.
7. `LocalAnswerModel.budgetedPrompt` caps actual model-facing memory at 900 tokens and validates the entire formatted request against an 8,192-token context with 1,536 output tokens reserved for journal answers. If the formatted prompt exceeds the limit, the fitter drops whole background records before original excerpts and preserves the complete question.
8. The local model streams complete UTF-8 text snapshots. `JournalAnswerPresentation` hides internal reference dumps. The app guards request IDs so cancelled work cannot overwrite a newer question.

The public `RetrievalRequest` initializer still has a five-result default for direct callers. The app uses the planner's **25-candidate** default and a variable budget-selected excerpt count; it is neither recent-only nor fixed at five.

Background memory influences generation, not the original evidence query or evidence ranking. Question-aware selection embeds the unchanged question separately. Original excerpts supply question-specific evidence. Both are untrusted/fallible data. Raw IDs remain host-side; the generation formatter strips source/memory identifier metadata and escapes role-token spellings. These mitigations do not prove resistance to natural-language prompt injection.

There is no autonomous tool loop, held-out validated relevance threshold, period-summary coverage or natural-language date routing.

## Storage and privacy

| Data | Persistence today |
| --- | --- |
| Original Journal database | Owned by Apple; read-only access |
| Metadata index | Private SQLite, metadata only |
| Personal memories and source links | Separate private SQLite content-derived store |
| Model weights | Private local files |
| Passage/memory embeddings, keyed revisions and passage UTF-8 locations | Separate private `Retrieval/embeddings.sqlite3` (document and memory namespaces) |
| Retrieved bodies, prompts, answers and query vectors | Transient application memory |

Metadata/memory/cache directory and file permissions are 0700/0600. They are not application-level encryption and do not exclude OS swap, crash capture or filesystem backups. Private text, prompts, raw model output and vectors must not enter diagnostic logs. Earlier exports from historical implementations are not opened, migrated or deleted automatically.

Freshness is defined by the successful preflight source snapshot. Later new/unselected edits are discovered at the next preparation; selected evidence is validated again before generation. This is not an atomic whole-history view and does not establish complete historical coverage.
