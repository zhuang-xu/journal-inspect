> Historical snapshot through 2026-11-05. Superseded by the [current documentation](../README.md). These claims describe earlier stages and are not current product instructions.

# Personal memory — 2026-11-05

Personal memory is optional local content-derived persistence. It starts disabled. The metadata index remains metadata-only, and original Journal access remains read-only.

## Use

1. Enable **Use personal memory** in **Memory**.
2. **Build suggestions** reads every synced journal entry and runs extraction again, including unchanged revisions. It preserves user corrections and forget decisions. It does not require a separate hidden rebuild action.
3. Built automatic memories become available as dated background whenever **Use personal memory** is enabled. Individual confirmation is optional: **Confirm** gives reviewed memories priority without making unconfirmed ones unusable. You can edit, forget, or mark a memory outdated.
4. Prepare an Assistant question. Background memory and original evidence have separate review disclosures. Generation refreshes source support and measures actual model tokens before answering.

After successful sync, enabled memory uses an incremental update: unchanged fingerprints, actual body revisions and processing versions can reuse extraction checkpoints. Explicit Build always runs full extraction. Cancellation retains completed facts; the next explicit Build reads the full indexed history again. New Journal entries must first be indexed with Sync Apple Journal.

## Extraction

`LocalMemoryExtractor` runs the selected pinned model for every passage. The preferred model is Qwen3-4B-Instruct-2507 Q5_K_M, upgraded from the 0.6B baseline. The former narrow English/Chinese pattern shortcut is no longer used in the production extraction path; model evaluation must measure actual inference. Model identity is recorded in processing versions so changed models invalidate incremental extraction checkpoints.

Each model request receives a bounded 3,000-byte passage. Candidates must have a valid category, size-bounded statement and a literal supporting quote from the source. Up to four candidates are accepted per passage, with an entry-level validation bound of twelve. This is not a global four-memory limit. Identical normalized statements consolidate and retain supporting sources. Semantic duplicates and conflicting statements still need review.

Malformed/unsupported model output is recorded as an entry extraction failure without preventing the remaining history from being read. Failed revisions are not checkpointed. Native runtime, source-access and cancellation errors can stop a run; aggregate status identifies incomplete work. Syntactic validation and a matching quote do not prove the interpretation is correct.

## Controls

User edits take precedence over model rewrites and survive changed/deleted sources and full builds. A correction attached to an entry conservatively suppresses further automatic candidates from that entry. Mark outdated preserves a user decision to exclude a fact; editing can reactivate it.

Forget removes a fact and retains hashes of its normalized statement for supporting source revisions. Forgetting a corrected fact suppresses its unchanged supporting revisions entirely. Restore forgotten suggestions clears those decisions and checkpoints. Delete all clears facts, checkpoints, reports and suppressions and disables memory; a later explicit build can recreate suggestions. Original Journal content and the metadata index remain intact.

## Storage, privacy and budgets

JournalCore contains the actor-owned store, records and resumable updater. JournalGeneration owns local model execution. The app serializes memory extraction against sync and Assistant generation.

Storage: `~/Library/Application Support/JournalInspect/Memory/personal-memory.sqlite3`, separate from the metadata index. Directory/file permissions are 0700/0600, with full-synchronous SQLite transactions, DELETE journaling, secure deletion, memory-only temporary storage and symlink rejection. This is private storage, not application-level encryption or a guarantee against backups/snapshots.

Source links retain entry identity, metadata fingerprint, decoded-body revision hash, journal date, exact quote location and processing version. Before prompt use, automatic facts reopen their originals and require at least one matching body revision. User-authored facts retain their explicit origin.

The stored set is independent of the active profile. Eligible user-authored memories have first priority, followed by confirmed memories and then the newest automatic memories, in a 3,600-byte preliminary profile, then the actual answer-model tokenizer caps memory at 900 tokens and checks the entire formatted request against an 8,192-token context with 768 tokens reserved for output. Whole records are omitted with visible counts; instructions and the original question are not truncated. Memory is fallible untrusted background and cannot supply journal citations.

## Diagnostics and current limits

The UI displays saved/state counts and persistent aggregate build results: completed/extracted/unchanged/unavailable/failed entries, candidate counts, nonempty decoded entries, total decoded UTF-8 bytes and entries yielding zero candidates. Earlier stores remain readable and show their existing checkpoints without inventing missing historical measurements. Diagnostics never include private statements, journal text or raw model responses.

The full-build development check exercised source reading and extraction. Sparse output from the initial model motivated more representative bilingual evaluation.

Synthetic tests cover full re-extraction, duplicate/source preservation, English/Chinese exact statements, privacy, corrections, revision/deletion invalidation, suppression/reset, cancellation, report persistence and earlier-store compatibility. Native tests cover the repaired pipeline's explicit goal case, actual token budgets and using a saved memory in an answer. The current native evaluation uses actual model inference without a pattern shortcut; the small development suite still does not establish broad real-history recall.


## Larger-model upgrade — 2026-11-05

The installed/default generation model is now Qwen3-4B-Instruct-2507 Q5_K_M, with its own verified checksum and non-thinking chat template. The production extractor now uses model inference for every passage, with explicit category definitions and literal quote validation. The model identity is part of processing version v5; no matching-rule shortcut is used in evaluation or production extraction. The old 0.6B weights remain available for manual comparison.

On twelve synthetic development cases, 4B found 10 of 10 expected positives and 0.6B found none. Both correctly returned no results for the two negatives. A separate development run had partial failures and retained valid results. See the [model evaluation](../MODEL_UPGRADE_EVALUATION.md).


## Automatic background and optional confirmation — 2026-11-05

The earlier mandatory per-item review gate was inconsistent with enabling built memory as background. New extracted records now have an explicit `unreviewed` state and are eligible for bounded prompt use after validating current original support. They remain automatically extracted, not user-confirmed. Confirmation is an optional priority/quality signal; user-authored corrections remain first priority. Outdated and genuinely clarification-required records remain excluded, and disabling memory still excludes all memory.

Existing pre-policy automatic records previously queued as awaitingClarification are interpreted as unreviewed under a versioned compatibility migration. Their original statements, dates, origins and source links are preserved; no extraction rerun or bulk user confirmation is fabricated. Once the new policy is present, explicit clarification records keep their exclusion. The prompt includes review metadata so automatic/unconfirmed content remains visibly distinguishable from confirmed/user-authored facts.

Native UI verification confirmed that eligible automatic background appeared in the bounded preview and that the interface displayed omission counts and source information.
