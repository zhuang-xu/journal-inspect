# Persistent embedding cache

Implemented in the Swift project on 2026-11-06. Reflect defaults to cached retrieval, independent of background memory. Under **Journal Settings → Answer Setup → Retrieval cache**, disable reuse for transient search or select Update, Rebuild or Clear cache. Disabling reuse retains disk contents; Clear removes document and memory vectors and rotates its private body-revision key. Originals, metadata, personal memories and weights remain independent.

Storage: `~/Library/Application Support/JournalInspect/Retrieval/embeddings.sqlite3` and a private `writer.lock`. Directories/files use 0700/0600 permissions; vectors are sensitive derived data, not encrypted. DELETE journaling, FULL synchronization, secure deletion and memory-only temporary tables avoid a persistent WAL/plaintext staging area. Filesystem backups/snapshots remain outside clear's guarantees. Foreign/incompatible database destinations and symlinks are rejected rather than overwritten.

## Refresh and reuse

Preparation runs the read-only metadata sync first. A successful sync commits source ID, random persistent index-instance ID and monotonic generation with the metadata changes. A consistent source-scoped manifest authorizes deletion reconciliation; failed/cancelled scans do not. Metadata retains no journal bodies or vectors.

The model loader hashes the actual embedding weights and checks the pinned checksum before native loading. The document namespace incorporates that checksum, native output dimension, runtime, document/tokenizer policy, LAST pooling, L2/cosine, chunking, Float32 codec and OS/native RTF decoder signature. The generation model and question instruction are excluded.

Unchanged metadata fingerprints reuse complete vectors. Changed fingerprints cause a current body/date read; matching keyed decoded-body revisions reuse vectors even after a date/title/asset change or metadata-index rebuild. Changed bodies are chunked with exact UTF-8 ranges and embedded. Empty entries publish a complete zero-passage version. Each replacement is staged one vector at a time in short SQLite transactions, revalidated against its current original, then atomically published. An incomplete draft cannot enter ranking. Compatible completed entries survive interruption; the next writer cleans abandoned drafts.

A separate advisory lock excludes concurrent updaters across actors/processes. Clear changes a persistent epoch so outstanding work cannot publish after reset. The app serializes active operations and drains cancelled model work before a new request. A second writer receives a retryable cache-busy error. Public concurrent warm-ups are rejected, rather than automatically coalesced.

After complete reconciliation, retrieval streams vectors and keeps only the best passage per entry and requested candidate pool. Selected originals are reopened, keyed body revisions and dates are compared, and the winning UTF-8 slices are decoded strictly. Evidence assembly then expands the slice within the validated original and records the final range. This does not alter indexed offsets, embedding-space identity or stored vectors. Selected changes cause refresh/reranking, bounded to two passes; continuous churn fails preparation. Host-side evidence references survive context/token fitting. The app validates the preview before loading the answer model and the fitted references immediately before inference. An invalid preview triggers fresh preparation. An invalid fitted reference stops generation. Transient search carries in-memory revisions that can be validated independently of cache storage.

## Failure and freshness boundaries

Cache-only failures identify the retrieval cache and offer Rebuild or disabling reuse for the existing transient search. Source errors propagate; cached text never conceals unavailable originals. Corrupt vectors/counts/locations are treated as misses and rebuilt during reconciliation. Required decoding/inference failures stop preparation; no partial ready subset is presented as complete history.

Each warm unchanged evidence search still hashes/loads the model, embeds one question, scans source fingerprints, validates cached vector rows, scans compatible vectors and reads selected originals. It performs **zero document embeddings**, including after a process/store restart. This is not zero I/O. Source freshness is the successful preflight snapshot; an unselected entry changed later may wait until the next preparation. There is no atomic whole-history source lock, calibrated relevance threshold or historical-coverage guarantee.

Explicit Sync reconciles the cache before starting optional existing memory extraction. Foreground preparation does not start background extraction or reload the 4B memory model. It does not currently notify the memory coordinator to schedule a later catch-up; memory support is independently validated when building the profile. Cache update status shows the last successful in-session ready/total count, passages, disk bytes, reuse/rebuild counts and source-check time; errors appear in preparation status. Failed-entry counts and last status are not yet retained across app launches.

## Implementation details and design differences

The implementation uses `entry_versions` with `complete` and `current` flags as the active header rather than a separate `cached_entries` indirection. Atomic publication switches the complete/current version and deletes superseded versions in one transaction. Coverage is recorded against the source/index instance/generation. Inactive model namespaces are pruned after successful completion. The lock has its own file to avoid interfering with SQLite's own database-file locks.

The existing chunker still materializes the current entry and its passage strings; vector staging and ranking are bounded by a vector/candidate pool rather than the whole corpus. There is no ANN dependency or vector extension. No bodies, titles, passages, questions or query vectors are persisted by this store; keyed decoded-body revisions use a separate random HMAC key with domain and length framing.

## Verification

Verification on 2026-11-06 after the live-button fix: 90 ordinary tests passed, nine opt-in checks skipped, no failures; the separate native bilingual equivalence check previously passed. The normal development-signed Debug Xcode build, deep strict signature verification and changed-file formatting checks passed.

The new fractional-source-date regression reproduced the false `sourceChanged` error before the fix. Source dates use Apple’s reference epoch and cached dates use Unix seconds; unchanged fractional timestamps can lose an ULP during an epoch round trip. Validation and inclusive-start/exclusive-end cache filtering now compare in the stored Unix epoch. Returned evidence retains the current original source date. The Assistant no longer disables its own Stop button through the parent view, and controlled source errors retain their actionable messages.

`EmbeddingCacheTests` uses synthetic SQLite sources only. Regressions cover warm different-question reuse, reopened-cache reuse, new entries, unchanged-timestamp edits, metadata/date-only edits, deletion, index rebuild, empty-to-filled bodies, Unicode locations, transient equivalence, preview edits/deletion/reset, clear during inference, cancellation/resume, malformed vector rebuilding, document-space changes, concurrent writers, source identity isolation, continuous edits, codec validation, failed-source preservation and absence of plaintext sentinels in cache files.

An opt-in native test compares cached/transient source IDs, passages and dates for a small bilingual synthetic corpus using the actual embedding weights:

```sh
JOURNAL_EMBEDDING_MODEL="$PWD/Models/Qwen3-Embedding-0.6B-Q8_0.gguf" \
  swift test --filter EmbeddingCacheTests/testNativeCachedAndTransientResultsMatch
```

Live verification clicked **Prepare context** twice in the development-signed app with the reported question. Both completed and enabled **Generate answer**, including 11 excerpts; aggregate cache status showed 326/326 entries ready, 327 passages, 326 reused and zero rebuilt. Evidence disclosures remained closed and no private prose was logged. The corrected build was left running. This is a live functional check, not a controlled cold/warm latency benchmark or general answer-quality evaluation.

Use the project’s normal signed build when testing Journal access. The earlier `CODE_SIGNING_ALLOWED=NO` app reproduced an immediate generic preparation failure; the normal development signature allowed the cache workflow to proceed. A compile-only unsigned build is insufficient verification of macOS runtime access.

## Question-aware memory vectors

Schema version 2 adds `memory_epochs` and `memory_vectors` to this same database. Opening version 1 migrates transactionally while preserving document vectors, settings, keys and coverage. Memory records are never inserted into entry/passage tables or validated as Journal UUIDs. Their namespace is a hash of the owning store directory, with memory UUID, domain-separated keyed statement revision and embedding-space identity. No statements or query vectors are stored.

The shared writer lock/space validation/vector codec apply to memory embedding too. Memory-store mutations invalidate affected IDs and rotate a per-store epoch, preventing in-flight inference from restoring forgotten vectors. Disabling or delete-all removes that store's memory vectors; explicit cache Clear removes both namespaces and rotates the global key/epoch. Failed/cancelled operations release the writer. Corrupt memory vectors are misses and are rebuilt from supported current statements.

Memory ranking finishes after evidence retrieval releases its writer. Generate refreshes the query-aware profile before loading answer weights; no embedding/generation model overlap is introduced. Unchanged warm profiles re-embed the question but not statements. See [memory selection evaluation](MEMORY_RELEVANCE_EVALUATION.md) for the operating point and known misses.
