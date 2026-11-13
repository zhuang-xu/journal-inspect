# Persistent journal embedding cache

Date: 2026-11-05

Status: Original implementation design. Core cache and app integration implemented 2026-11-06; see [actual behavior and validation](../EMBEDDING_CACHE.md). This document retains the original design, including promotion goals that are not all verified.

Application: Journal Inspect for macOS

## Decision

Add a private SQLite cache of passage embeddings in JournalCore. Retain the existing local embedding actor, exhaustive cosine search, current-source reader, prompt budgets and source mappings. Save vectors and passage locations, not original journal bodies or search questions.

Use a dedicated sibling store:

`~/Library/Application Support/JournalInspect/Retrieval/embeddings.sqlite3`

Keep `journal-index.sqlite3` metadata-only and leave the existing `Memory/personal-memory.sqlite3` unchanged. The earlier roadmap proposed one shared derived store; a sibling database is the smaller first implementation now that personal memory has shipped. It allows independent reset without migrating working memory data. No vector extension, external service, Python application runtime or new server is needed.

**The 4B answer/memory model does not create these vectors.** Continue using Qwen3-Embedding-0.6B Q8_0. Changing the answer model alone must not invalidate the retrieval cache.

## Current code and required changes

`SemanticJournalRetriever.retrieve` currently reads all synced current bodies, splits them, calls `embedDocument` for every passage and retains the best passage per selected entry. `OnDemandJournalSource.page` discards metadata fingerprints and passage offsets. `JournalPassages.split` returns strings without locations. `JournalTextEmbedding` has no verified embedding-space identity. The existing SQLite wrapper binds text only; it cannot yet bind vector blobs.

| Component | Responsibility |
| --- | --- |
| `JournalEmbeddingCache` actor, JournalCore | Private schema, binary vector storage, short transactions, staged versions, coverage and reset epoch |
| `JournalEmbeddingCacheUpdater`, JournalCore | Compare source manifest to cache, read changed bodies, reuse or embed passages, publish complete entry versions |
| `CachedJournalRetriever`, JournalCore | Embed the question, scan compatible vector batches, rank, reopen/validate originals, return ordinary `JournalEvidence` |
| `JournalPassages` | Return text plus exact UTF-8 offset/length; preserve current chunking behavior for v1 |
| `JournalReader` / `JournalMetadataStore` | Return a source-scoped successful-sync receipt and consistent metadata manifest; load current body and dates together |
| `LocalEmbeddingModel`, JournalEmbeddings | Verify actual weights and expose their embedding-space descriptor and actual vector dimension |
| App coordinator / `PromptViewModel` | Freshness check, shared update task, progress/cancellation, cache controls; unload embeddings before generation as today |

Keep the existing transient retriever as an explicit fallback when the cache itself is unavailable. Source-access errors must not be disguised as cache errors or bypassed with old evidence.

## New journals and freshness

A vector cache is not an importer. New journals become searchable only after their source identities and revisions have been discovered.

Before each context preparation:

1. Run the existing read-only Journal metadata synchronization on a worker. It still scans and fingerprints source rows; there is no proven private-schema change feed to replace that safely. Do not rely solely on `modified` timestamps—current tests allow body edits without timestamp changes.
2. Obtain a successful-sync receipt with current `sourceID`, a persistent random `indexInstanceID`, and a monotonic metadata generation committed with that sync. Read an immutable metadata manifest for that source in one index read transaction; do not stitch together independently changing offset pages.
3. Reconcile the cache against that manifest and update only missing/stale entries.
4. Rank compatible vectors and validate selected originals.

The first implementation intentionally retains an O(history) metadata fingerprint scan per question. It removes repeated document embedding inference and avoids decoding unchanged bodies for the cache. It does **not** promise zero source I/O on a warm question.

A foreground freshness check must call the core synchronization operation, not the current UI `ReaderViewModel.synchronize()` action wholesale: that action also clears UI state and starts memory extraction. Publish the sync receipt to the memory coordinator separately. Required retrieval updates get foreground priority; optional memory catch-up is coalesced and does not reload the 4B model on every unchanged search.

On explicit Sync Apple Journal, run the same reconciliation. Do not implement two independent sync/cache pipelines. A file watcher can be a future refresh hint; it cannot be the authority because Journal may update WAL files, the app may be closed, and filesystem events can be missed.

| Future change | Cache action |
| --- | --- |
| New journal | Read/chunk/embed that entry only; retain existing vectors |
| Edited body | Rebuild that entry's passage set and replace it atomically |
| Date/title/asset change with identical decoded body | Update metadata after checking body revision; reuse vectors |
| Deleted journal | Remove its eligible cache header and vectors after a complete authoritative reconciliation |
| Empty new journal, later filled | Record a complete zero-passage version; the later changed fingerprint triggers embedding |
| App closed while entries were added | Next freshness check discovers the new IDs and fills those misses |
| Different Journal source | Use its source identity; never reuse another store's same-looking UUID |
| Answer model changes | No vector invalidation |
| Embedding/document-processing changes | Use a new embedding-space namespace; rebuild compatible vectors |

Memory enable/disable and retrieval-cache enable/disable remain independent. Disabling personal memory must not break RAG caching.

## What identifies reusable vectors

An embedding-space descriptor contains:

- SHA-256 of the **verified actual embedding weights**, not just a filename or an assumed constant;
- actual output dimension, tokenizer/special-token policy, pooling (`LAST`) and normalization/metric;
- document input format version, llama runtime version and decoder signature;
- chunking version, currently 768 UTF-8 bytes with the existing Unicode-safe/whitespace boundary rules;
- vector encoding (`float32-le-v1`).

Canonicalize the descriptor and hash it to obtain `space_id`. Dimensions come from the loaded native model, not a hard-coded guess. Native RTF decoding is part of content processing; include an implementation revision and OS build identifier conservatively, since the native decoder can change after an OS update.

The question-prefix/instruction version is a separate query configuration. Changing only the query instruction does not alter stored document vectors; changing document formatting, weights, dimensions, tokenizer/pooling or decoder/chunker semantics does.

Each cached entry also stores:

- `(sourceID, entryUUID)`;
- the indexed fingerprint last reconciled;
- a keyed revision of the **actual decoded text embedded**;
- current journal date from a consistent source read;
- expected passage count and exact UTF-8 offsets/lengths.

Use a cache-private random HMAC key for decoded-body revisions, with domain separation and length-framed input. Do not expose unkeyed short-text digests in diagnostics. Keep this key independent of the metadata index's key so rebuilding the metadata index need not force native re-embedding when decoded bodies remain unchanged.

An indexed fingerprint is an efficient change signal, not proof that the text read later matches the index snapshot. Body revision and revalidation close that gap.

## Schema

Use ordinary SQLite BLOBs and scan vectors in Swift. A complete entry can have zero passages. A draft version is never search eligible.

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
PRAGMA secure_delete = ON;
PRAGMA temp_store = MEMORY;
PRAGMA application_id = 1246645301;
PRAGMA user_version = 1;

CREATE TABLE cache_settings (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL
);
-- cache_epoch, private revision key, descriptor/codec versions and preferences.

CREATE TABLE embedding_spaces (
    space_id TEXT PRIMARY KEY,
    descriptor_json TEXT NOT NULL,
    dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 65536),
    created_at REAL NOT NULL
);

CREATE TABLE entry_versions (
    version_id INTEGER PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES embedding_spaces(space_id),
    source_id TEXT NOT NULL,
    entry_uuid TEXT NOT NULL,
    indexed_fingerprint TEXT NOT NULL,
    body_revision BLOB NOT NULL CHECK(length(body_revision) = 32),
    effective_date REAL,
    passage_count INTEGER NOT NULL CHECK(passage_count >= 0),
    is_complete INTEGER NOT NULL CHECK(is_complete IN (0, 1)),
    created_at REAL NOT NULL,
    UNIQUE(space_id, source_id, entry_uuid, version_id)
);

CREATE TABLE cached_entries (
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    entry_uuid TEXT NOT NULL,
    active_version_id INTEGER NOT NULL,
    is_current INTEGER NOT NULL CHECK(is_current IN (0, 1)),
    PRIMARY KEY(space_id, source_id, entry_uuid),
    FOREIGN KEY(space_id, source_id, entry_uuid, active_version_id)
      REFERENCES entry_versions(space_id, source_id, entry_uuid, version_id)
);

CREATE TABLE passage_vectors (
    version_id INTEGER NOT NULL REFERENCES entry_versions(version_id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    utf8_offset INTEGER NOT NULL CHECK(utf8_offset >= 0),
    utf8_length INTEGER NOT NULL CHECK(utf8_length > 0),
    vector BLOB NOT NULL CHECK(length(vector) > 0 AND length(vector) % 4 = 0),
    PRIMARY KEY(version_id, ordinal)
);

CREATE INDEX entry_versions_source ON entry_versions(space_id, source_id, entry_uuid);
CREATE INDEX entry_versions_dates ON entry_versions(space_id, source_id, effective_date);

CREATE TABLE cache_coverage (
    space_id TEXT NOT NULL REFERENCES embedding_spaces(space_id),
    source_id TEXT NOT NULL,
    index_instance_id TEXT NOT NULL,
    metadata_generation INTEGER NOT NULL,
    total_entries INTEGER NOT NULL,
    ready_entries INTEGER NOT NULL,
    failed_entries INTEGER NOT NULL,
    checked_at REAL NOT NULL,
    PRIMARY KEY(space_id, source_id)
);
```

All cache timestamps use UTC Unix seconds. `effective_date` is the current Journal entry date, falling back to source creation date, converted through `Date` from Apple's reference epoch; NULL remains undated. It is distinct from the cache processing timestamp `created_at`. Date filters retain inclusive-start/exclusive-end behavior.

Only join headers where `is_current=1` to versions where `is_complete=1`. Check source identity, descriptor/dimension, expected row count, finite/nonzero vectors and `vector.count == dimensions * 4` in the actor before publishing/using a version. App-layer checks reject mismatched source/version links even before foreign-key errors.

Store normalized vectors as explicitly encoded little-endian Float32. Do not use JSON arrays or Base64. Decode unaligned data safely and reject invalid lengths, infinities, NaNs, zero norms and invalid offsets. Re-normalize during scoring as the current retriever does if needed to preserve numerical behavior. A broken cache row is a miss, not evidence.

Extend the SQLite wrapper with typed bindings including `.blob(Data)`, `.integer`, `.real`, `.text` and `.null`, retaining existing callers. Parameterize all data writes; never construct SQL from journal contents. Do not share raw `Database` or `Statement` handles across actors.

## Refresh and atomic publication

1. After successful source sync, reconcile a complete, source-scoped metadata manifest. Mark changed headers non-current before inference. Remove missing/deleted entries only after the whole manifest succeeds. A cancelled/failed scan cannot authorize mass deletion.
2. For an unchanged fingerprint and compatible complete entry version, reuse vectors without reading/decoding the body again for cache preparation.
3. For a new/changed entry, load its actual body and current dates from one source transaction. Compute its keyed body revision. If the body revision matches the previous complete version, reuse its vectors and update date/fingerprint metadata.
4. Otherwise create a draft `entry_versions` row. Embed passages in bounded batches and write draft vectors in short transactions. Do not hold a SQLite transaction or a Journal source transaction open during model inference.
5. Reopen the original after embedding and verify source identity/body revision; verify the metadata generation or restart reconciliation when it changed. Reject a source that changed during the build.
6. In one transaction, verify the reset epoch and job ticket, validate all rows/counts, set the version complete, switch the active header, and delete the superseded version. Only then is the replacement visible.
7. Record aggregate coverage against that manifest. Successful complete entries survive cancellation, errors and app restarts. On next startup, discard orphan draft versions under the single-writer coordinator and resume missing/stale entries.

Draft staging avoids retaining all vectors from a very long entry in RAM. It also prevents a partially rebuilt entry being mixed with its old passage layout. Keep at most one active draft per entry/space and bound batch bytes. Cleanup/pruning must not race a live writer; use an exclusive writer ownership lock plus SQLite transactions for cross-process safety. A second process can fall back to transient retrieval rather than erase another process's draft.

If any required entry cannot be decoded/embedded, leave it non-current and report incomplete cache coverage. In v1, do not silently search only the ready subset as if all history was searched: fail preparation with a retryable incomplete-index status. An explicit partial-search mode can be added later with propagated coverage information. Genuine concurrent deletion is reconciled as removal, not a failed embedding.

## Search on a warm cache

1. Perform the freshness/reconciliation sequence above and finish required incremental work.
2. Embed the current question once with the verified same embedding model.
3. Read compatible/current vectors in bounded batches, with source and explicit date-window filters. Compute cosine/dot-product scores in Swift; retain the best passage per entry and the current 25-entry candidate pool. Preserve deterministic tie ordering.
4. Reopen selected originals, verify source identity/body revisions and current dates against any requested date bounds, then extract the exact saved UTF-8 slices. Validate Unicode boundaries; never silently decode corrupt ranges with replacement characters.
5. If selected evidence was changed/deleted during search, invalidate or rebuild it and rerank/refill. Bound the repair loop, initially two passes; report continuous source churn rather than loop forever or return stale text.
6. Return the existing `JournalEvidence` objects to the unchanged budgeted context builder and answer-tokenizer flow. Internal source IDs remain host-side as currently implemented.

A prepared preview is another snapshot, not a permanent validity guarantee. Carry host-side `JournalEvidenceReference` values (source/entry identity, body revision and passage range) through `JournalEvidence` and `JournalContext` for included records. Before Generate answer loads 4B, revalidate those selected originals again. If they changed, refresh the affected vectors/evidence with the embedding model, update the preview, unload embeddings, and only then load 4B. Source references must be filtered along with records when context/token budgeting removes excerpts. They are not sent to the model. Handle continuous edits with the same bounded retry policy; do not generate from an invalidated preview merely because its text is still in RAM.

Warm unchanged searches perform **zero document embeddings**, including after app restart. They still require one query embedding, model loading under the current lifecycle, the metadata freshness scan and selected-original reads. Query vectors and questions are transient and are not persisted in v1. These I/O counts describe retrieval; the existing background-memory profile also validates its own supporting sources independently. Do not claim that the whole application reads only the selected RAG entries.

Search freshness is defined by the successful preflight source snapshot. A journal created after that snapshot is picked up by the next refresh. Revalidating selected originals prevents stale chosen evidence; it cannot guarantee recall for an unselected entry that changes after the snapshot. Be explicit about this boundary instead of promising an atomic live view of all Journal content.

## Coordination and failure behavior

The App owns one refresh/search operation at a time. Coalesce simultaneous warm-up requests. Capture a reset epoch and request ID; every publication checks them inside its transaction. Clear/rebuild/cancel/source-switch invalidates outstanding tickets. Native calls remain cooperatively cancellable between calls, as today; late model output cannot repopulate a cleared cache.

Keep the embedding model owned by its existing actor and unload it before loading the 4B generation model. Disk persistence does not require keeping weights or every vector resident in RAM. Scan vector batches with cancellation checks; do not force the entire future corpus into memory.

- Cache-only permission/disk-full/schema/corruption errors: report the cache problem distinctly, then allow the existing transient search path if the original source/model are usable. Do not tell the user to grant Journal Full Disk Access to repair a cache directory.
- Source permission denial or source identity mismatch: stop; do not use old cache contents to conceal unavailable originals.
- Corrupt/incompatible vectors: invalidate and rebuild the affected entry; never rank malformed data.
- Clear: change the epoch first, remove only cache-owned vector/version/coverage rows and rotate the cache revision key. Do not unlink a database underneath an active connection.
- Embedding namespace change: no mixing old/new vectors. Build the new namespace; prune inactive namespaces after use is safely switched, with bounded retention. A generation-model change alone does nothing to this cache.

The current sync status contains aggregate counts but not a stable manifest generation/source receipt. Add that metadata-only revision tracking. A metadata-index rebuild creates a new index-instance ID; never compare generation counters from different index instances as if they were one sequence. Reconcile fingerprints/body revisions while retaining compatible vectors when possible. Do not infer a complete change set from `SyncResult.changed` alone.

## UI and privacy

Add a compact Retrieval cache section with enable/disable, Update, Rebuild and Clear cache. Display ready/total entries, passage count, disk size, last source check and aggregate build failures. Preparation progress distinguishes source checking, missing-vector updates, cache search and original-evidence validation. A second question should report cached reuse rather than imply a full rebuild.

Clear retrieval cache leaves original Journal entries, the metadata index, model weights and background memories untouched. Disabling cache uses transient retrieval and does not silently delete stored vectors. Explain that embeddings are sensitive content-derived data.

Apply the existing private-file creation pattern: private 0700 directory, 0600 database, no symlink destination, application/schema identity checks before modifying existing content, full-synchronous transactions, DELETE journaling and memory-only temporary storage. Verify sidecar protection and use cache-specific errors. Do not claim these permissions are encryption or that secure deletion removes filesystem snapshots/backups.

No titles, bodies, passage text, questions, raw vectors or private statements in logs. Diagnostics may retain bounded aggregate counters: hits, misses, document/query embedding counts, rebuilt/removed entries, failures, coverage, byte size and latency.

## Implementation sequence and acceptance

1. **Source/identity contracts:** verified embedding descriptor; located passages; current body/date material; source-scoped sync receipt and consistent metadata manifest.
2. **Store:** private schema, typed binary binding/codec, staged atomic entry publication, reset epochs and corruption handling.
3. **Updater:** initial build, manifest reconciliation, new/edit/delete/empty handling, body-hash reuse and resumable cancellation.
4. **Retriever:** batched vector ranking, current-original validation/refill, existing context integration and explicit fallback.
5. **App:** foreground freshness, shared operation ownership, selected-reference revalidation before generation, progress/controls and independent reset scope.
6. **Validation/promotion:** synthetic regressions, opt-in native equivalence checks, aggregate-only real-history cold/warm/restart measurements, then normal signed app/UI verification.

Required checks:

- Same corpus, different questions: zero additional document embeddings on the second search; query embedding occurs for each question.
- App/store restart: same zero-document-embedding result with a valid cache. A rebuilt metadata index changes its instance/key but can still reuse vectors after decoded-body revision checks.
- New journal added while app closed: next preflight detects it; only its passages are embedded, and it can win retrieval over old entries.
- Edit with unchanged source modified timestamp: fingerprint detects it; only its entry changes. A body-identical metadata/asset edit causes zero re-embeddings.
- Deletion before search, between ranking/materialization, and after preview but before generation: no deleted evidence; refill/refresh where possible.
- A date-only edit moves an entry across a date filter without native re-embedding. Cache dates use the correct Unix epoch after source timestamp conversion.
- Interrupted metadata scan: no mass cache purge. Interrupted entry embedding: no draft is searchable; completed entries remain reusable.
- Clear during inference and source/model changes: no late publication or namespace mixing.
- Invalid vector dimensions/BLOBs/values/UTF-8 offsets: clean cache miss/rebuild or explicit error, never stale/wrong text.
- Empty body then later text, long Unicode entries, source UUID collisions across different stores, and dates changed independently of body.
- Storage inspection: no body/title/question sentinels in the cache, including staging/sidecar behavior; original Journal remains read-only and the metadata index stays metadata-only.
- Cached results match the existing transient retriever on labeled fixtures within documented floating-point tolerance, preserving selected passages and date behavior.

For storage planning, vector payload alone is `passageCount × dimensions × 4` bytes. For example, 10,000 passages at a hypothetical 1,024 dimensions are about 39 MiB before SQLite metadata/index overhead. Read the actual model dimension before displaying a concrete estimate. Keep exhaustive scanning first; consider a specialized ANN index only if measured corpus size and warm latency justify it.
