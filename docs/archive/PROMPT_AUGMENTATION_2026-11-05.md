> Historical snapshot through 2026-11-05. Superseded by the [current documentation](../README.md). These claims describe earlier stages and are not current product instructions.

> Retrieval update (2026-11-03): the app now uses SemanticJournalRetriever across synced history, selecting up to five entry excerpts. JournalQueryPlanner passes the question through without inferring dates. The recent-only behavior below describes the original milestone. See EMBEDDINGS.md for current implementation and limitations.

> Answer generation is now implemented locally with llama.cpp and Qwen3. The UI is **Journal assistant — local Qwen**; see [GENERATION.md](GENERATION_2026-11-05.md) for current usage. The document below records the initial prompt-only milestone.

# Prompt augmentation milestone — 2026-11-03

Phase 1 remains metadata-only persistence plus on-demand Apple Journal reads. This milestone adds an in-memory path in JournalCore:

User prompt → RetrievalPlanning → JournalRetrieving → ContextBuilding → AugmentedPrompt → optional JournalAnswerGenerating → answer.

## Try it

Build/run JournalInspectApp, sync the index, expand **Prepare a journal-aware prompt**, enter a question, and choose **Prepare context**. The app previews instructions, JSON evidence and the original prompt. It calls no model and sends no network requests. Clear removes the prompt and preview; synchronization and view disappearance also clear them and cancel pending work. Swift memory release does not guarantee secure erasure or prevent OS swap/crash capture.

The default RecentJournalPlanner requests five newest indexed nondeleted entries, ordered by entry date with creation fallback. It does not interpret the question, parse dates or perform semantic search. Sync first: new entries absent from the index cannot be retrieved. The existing embedding foundation remains independent; no vectors are persisted.

## Swift interfaces

- `JournalRetrieving.retrieve(_:)` accepts query, optional inclusive-start/exclusive-end dates, and limit. OnDemandJournalRetriever uses metadata to select candidates, then opens current text directly from Apple Journal on a detached worker. A store handle is created and used on that worker only. Limits are 1–50; source identity/deletion checks remain in JournalReader. Unavailable entries are skipped; other failures propagate. Each entry has its own consistent source transaction; the entire result is not one atomic snapshot.
- `RetrievalPlanning.plan(for:)` returns zero or multiple requests, allowing no retrieval, multiple date windows, or future semantic/hybrid policies. The augmenter caps plans at eight requests, each at most 50 entries. The default is deliberately recent-only.
- `ContextBuilding.build(from:tokenBudget:)` preserves retrieval order, deduplicates source/UUID identities, skips empty text and whole entries that do not fit, and returns included citation IDs plus an omission count. It never silently truncates a journal body. Omission count describes unique supplied evidence, not missing/deleted source rows or entries outside retrieval limits.
- `BudgetedContextBuilder` budgets serialized JSON UTF-8 bytes as a conservative proxy for byte-based tokenizers. Default context budget is 4096; accepted range is 2–1,000,000. This is not an exact model tokenizer or a total request limit: model adapters must reserve room for instructions, question, tool schemas, history and answer, and apply their model's tokenizer. Candidate bodies are read in full before context selection; this budget does not cap transient reader memory.
- `PromptAugmenting.augment(_:tokenBudget:)` preserves the original user prompt separately from evidence and instructions. Evidence is encoded as JSON, with citation identity and optional ISO-8601 date. Instructions treat evidence as untrusted data, require citations, and state uncertainty. This separation is a mitigation, not a guarantee against prompt injection.
- `JournalAnswerGenerating.answer(_:)` and `JournalAssistant` provide the optional answer path. Supply an explicitly chosen local or remote client. No production model client is installed. A remote adapter would disclose selected bodies and the prompt to its provider; the host must make that choice explicit, enforce its privacy policy, and avoid request/response logging. Map instructions to the model's instruction role and evidence to a separate data message; do not promote journal content to system instructions.
- `AgentTool` exposes a name, summary, JSON input schema and async call returning JournalContext. It is an extension contract only: no autonomous loop, tool registry, argument validator, permissions policy or executing tools are enabled. Future implementations own those checks.

Evidence, context and augmented prompt diagnostics are redacted. The database schema and import path are unchanged. These new content-bearing types are not Codable; context serialization is transient only. No body cache, export, prompt history, analytics or attachment loading was added. Consumers must preserve this boundary. Cancellation propagates to detached retrieval; cancelled/stale app requests cannot repopulate cleared previews.

## Apple Journal access limitations

This app continues its existing direct read-only access to Apple's private local SQLite store at `~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite`. This is an implementation-dependent local format, not a supported Journal entry API. OS changes, source availability, encryption/locking, unsupported schema, SQLite coordination and macOS privacy permissions may prevent reading. Full Disk Access may be required for the actual signed launching app; nothing here changes permissions or bypasses TCC. There is no iCloud retrieval or iPhone database access.

Apple's public [Journaling Suggestions framework](https://developer.apple.com/documentation/journalingsuggestions) provides suggestions a person chooses to share through its picker. It should not be treated as an API for reading their existing Apple Journal history. This milestone adds no Apple entitlement or new access mechanism.

## Verification

`swift test` uses synthetic SQLite fixtures (the existing real-Journal test stays opt-in). Prompt tests exercise current-body reads after edits, stale deletion exclusion, date boundaries, limits, index privacy sentinels, citation deduplication, Unicode/hostile JSON text, budget omission, no-retrieval/multiple-request plans, propagated errors, cancellation and a synthetic injected answer generator. The app target is also built separately to check SwiftUI integration. No real journal bodies or model/network requests are needed for validation.
