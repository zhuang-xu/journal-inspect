# Personal memory

Current implementation, source-checked 2026-11-06. Background memory and RAG evidence serve different roles: stored memories supply dated personal context; retrieved original passages supply question-specific evidence. Memory does not currently rewrite the embedding query or influence retrieval ranking.

## Using memory

Memory starts disabled. In **Journal Settings → Personalization**, enable **Use personal memory**, then choose **Build suggestions** after synchronizing Journal entries. The explicit build reprocesses every indexed entry, even unchanged ones, without a separate rebuild action. It preserves user corrections and forget decisions. Successful sync also starts incremental catch-up when memory is enabled.

Built source-supported automatic memories become available as background immediately when enabled. They are **not** silently marked user-confirmed. Confirming an item is optional and breaks exact relevance ties; it does not make unrelated background relevant. Existing records from the former mandatory-review queue are interpreted as unreviewed by a versioned compatibility migration, without rerunning extraction or claiming user approval.

| State/action | Meaning |
| --- | --- |
| Automatic/unconfirmed (`unreviewed`) | Eligible after validating current original support; labeled automatically extracted |
| Confirmed (`active`) | User-confirmed or user-authored background; eligible for question-aware selection |
| Outdated | Excluded from the profile |
| Needs clarification | Excluded until explicitly resolved; distinct from ordinary unreviewed memories |
| Edit | Creates a user correction that takes precedence over automatic rewrites |
| Forget | Removes an item and suppresses its unchanged supporting revisions |
| Restore forgotten suggestions | Clears forget decisions/checkpoints; a later build can recreate suggestions |
| Delete all memory | Clears memories/checkpoints/suppressions/reports and disables memory; original Journal/index stay intact |

Source controls open the current original, which may differ from the version used during extraction. A correction linked to an entry conservatively suppresses further automatic candidates from that entry, potentially including unrelated facts. User-outdated decisions survive builds; editing can reactivate the item.

## Extraction and incremental behavior

`PersonalMemoryUpdater` reads indexed current bodies in bounded 3,000-byte passages. `LocalMemoryExtractor` uses the selected verified generation model for every passage. The unused regex-based extractor has been removed. Processing versions include model identity.

The model proposes short circumstances, goals, preferences and relationships with literal source quotes. Categories, sizes, counts and quotes are validated before a complete entry commits. Up to four candidates per passage and twelve per entry are permitted; four is not a global memory limit. Identical normalized statements consolidate and retain supporting links. Semantic duplicate merging and automatic conflict resolution are not implemented.

Unchanged fingerprints plus decoded-body revision and processing version can skip inference during incremental updates. Explicit Build forces extraction again. Changed sources replace their old automatic contributions; removed support makes unsupported automatic facts outdated. User-authored corrections retain their own origin.

Malformed/unsupported output for one entry leaves it retryable and processing continues. Completed entries survive cancellation. The report stores total/checked/extracted/unchanged/unavailable/failed counts, candidates, decoded-byte/nonempty counts and timestamps. A run with any rejected entry outputs currently reports `failed`, even when it checked all entries and saved other results. This denotes partial extraction, not that the saved list was discarded.

## Profile selection and storage

Storage: `~/Library/Application Support/JournalInspect/Memory/personal-memory.sqlite3`, separate from the metadata-only index. It contains statements, dates, source IDs/revisions/quote locations, origin/state, processing versions, checkpoints and suppression decisions. Permissions are 0700 for the directory and 0600 for the database; the store uses actor serialization and SQLite transactions. This is not application-level encryption.

Only enabled, eligible memories enter a profile. Automatic records reopen their originals and require at least one matching decoded-body revision. Missing/unreadable/changed support excludes that item. User-authored items retain their explicit origin.

`PersonalMemoryStore.profile(for:embeddings:...)` embeds the unchanged question with the existing query method and eligible statements with the document method. Cosine similarity determines order. Statements below 0.5 are omitted; zero selected memories is supported. This operating point is specific to the pinned Qwen embedding model and a small development evaluation, not a probability or general relevance guarantee. See [selection evaluation](MEMORY_RELEVANCE_EVALUATION.md).

At exactly equal scores, user-authored/edited records precede automatic records, confirmed precedes unreviewed, then newer as-of dates and stable UUIDs break ties. No unvalidated relevance band or semantic-equivalence merging is used. Exact normalized duplicates are removed; negations and conflicting dated statements remain distinct. Ordinary autobiographical `.preference` records remain background, not instructions.

There is no preliminary 3,600-byte profile cap. All selected records reach the existing generation fitter, which removes trailing, lower-ranked whole records until model-facing memory fits 900 actual tokens and the complete request fits. Omission counts include unsupported, below-cutoff, duplicate and tokenizer-removed records. Model-facing metadata preserves dates, origin and review state.

The existing private embedding cache now has a separate memory namespace, keyed by store identity, memory UUID, keyed statement revision and embedding space. No memory is represented as a Journal entry. Unchanged requests reuse statement vectors, while each request embeds its own question. Edits, forgetting, outdated decisions, disabling and delete-all invalidate affected vectors; namespace epochs reject stale in-flight writes. Clear cache resets both vector namespaces. Disabling cache reuse computes transient vectors without storing them.

Generate refreshes selection with embedding weights and unloads them before loading the answer model. After that load, it checks the memory-store revision and selected original support again. Concurrent changes stop generation with a request to prepare again. This avoids loading both model families together and does not change independent Journal evidence retrieval.

Disabling excludes all memory from prompts and stops automatic updates without deleting the store. Forgetting stores hashes of normalized statements per source revision; forgetting a user correction suppresses its unchanged supporting revision entirely. Source files and model weights are not deleted by memory controls.

## Limits and evidence

A matching quote does not prove a proposed interpretation is true. Automatic memories can be wrong, stale in meaning, redundant or missing. Dates reflect journal support, not processing time. No recurring trait should be inferred solely from a transient mood, and the current system has no comprehensive historical synthesis.

The [model evaluation](MODEL_UPGRADE_EVALUATION.md) describes how a partial 4B extraction retains successful results and leaves rejected revisions retryable.

Synthetic tests cover automatic inclusion without fabricated confirmation, legacy queue migration, current-source validation, corrections/outdated preservation, disabling, exact-score date priority, selection/caching, tokenizer budgets, deduplication, suppression/reset, cancellation and build-report compatibility. The [status](STATUS.md) lists recorded validation; detailed earlier behavior is in the [archive](archive/README.md).
