# Question-aware memory selection — 2026-11-06

The Assistant now selects background against the original question during Prepare and refreshes it with the same policy during Generate. This changes memory inclusion, not extraction accuracy or independent Journal evidence retrieval.

## Policy and ownership

`PersonalMemoryStore` owns eligibility, current-source validation, revision checks and embedding orchestration. `PersonalMemorySelection` owns the cosine operating point, deterministic order, normalized exact deduplication and profile serialization. Core depends only on the existing embedding contract, not llama.cpp. `JournalPromptService` owns loading/unloading native embeddings; the composition root explicitly shares the vector cache with the memory store.

Eligible statements use the existing document embedding method; the unchanged question uses the existing query method. Finite, nonzero vectors and dimensions are validated. Scores below 0.5 are rejected. At exact score ties, user corrections, confirmation, recency and UUID determine order. No empirically unvalidated near-tie band, semantic duplicate merger, interpretation classifier or new model family is introduced. Relevant negations and dated contradictions remain distinct. Autobiographical preferences remain background rather than response instructions.

All selected whole records reach the existing answer-model tokenizer: the old 3,600-byte profile cap is removed. The 900-token memory cap, full formatted-input limit and complete question preservation remain. Final fitting trims background memory before original evidence when the formatted prompt exceeds the input limit.

Generate refreshes background before loading answer weights, then checks the store revision and selected source support after loading. Concurrent changes fail visibly and require preparation again. Embedding/generation resources do not overlap. Disabling memory or an empty eligible store avoids a Generate-time embedding load. No private statements, prompts, answers or vectors are logged.

## Development operating point

An earlier isolated 14-case baseline included 9 irrelevant memories among 16 selected and retained 7 of 8 labeled relevant memories; the small byte-budget case dropped useful background in favor of an unrelated confirmed fact. Those historical artifacts remain in the separate adapter workspace, under `evaluations/memory-relevance/`.

The expanded native development set lives in `MemoryRelevanceNativeTests`: 20 English/Chinese cases, 41 candidate statements, 17 labeled relevant statements, and six cases with no relevant background. The fixture set informed policy development and is not held out. It covers lookup/background questions, cross-language matching, negation, changed preferences, and unrelated memories. Source/correction/reset behavior is covered separately by deterministic tests with real synthetic stores.

Using pinned Qwen3-Embedding-0.6B-Q8_0 (`06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439`, runtime `b12038`), a sweep of the recorded native similarities gives:

| Minimum cosine | Relevant retained / 17 | Irrelevant included |
| --- | ---: | ---: |
| 0.40 | 17 | 3 |
| 0.45 | 15 | 1 |
| **0.50** | **15** | **0** |
| 0.55 | 15 | 0 |
| 0.60 | 13 | 0 |

The initial 0.5 operating point favors excluding unrelated background. It returns no memories in all six labeled negative cases and retains both dated statements in each preference-change case. It is not a calibrated probability, a universal cutoff, or a guarantee that selected text directly answers a question.

Known misses remain labeled relevant: the English career-goal/interview statement scores 0.4165 and the Chinese equivalent 0.4482. In the English case, a cycling preference scores 0.4506, higher than the relevant goal. No single cosine cutoff perfectly separates these examples. Lowering the threshold to recover all relevant statements also admits unrelated background. Thus 15/17 recall (88.2%) on this development set must not be presented as a no-regression or general quality guarantee. Original evidence retrieval remains available independently.

## Cache and freshness verification

Schema version 2 extends the existing private SQLite vector cache with memory namespaces. Keys include store-directory identity, UUID, domain-separated keyed statement revision and the full embedding-space descriptor. Vectors reuse the existing codec, writer lock, storage permissions, reset key and global epoch. Statement text and query vectors are not persisted.

Tests verify warm and reopened reuse, changed-statement-only re-embedding, immediate vector removal on forget/disable/delete-all, transient mode without new vector persistence, embedding-space changes, corrupt-vector rebuilding, v1 migration retaining document-vector bytes, and Clear resetting both namespaces. A namespace epoch prevents in-flight inference from republishing a forgotten vector. Store edits during transient inference and selected-source edits during model loading are rejected too.

## Recorded checks

- Full package suite: 114 discovered, 105 passed, nine native opt-in tests skipped, zero failures.
- Separate native run: four passed, zero skipped/failures. This includes the 20-case selector, existing cached/transient evidence equivalence and cross-language retrieval, and actual 4B tokenizer fitting of an oversized selected-memory profile.
- Changed Swift files: strict formatter lint passed. Xcode project regenerated from `project.yml`; explicit product names preserve existing app/CLI names.
- Normal development-signed macOS Debug application build passed. Application wiring was compiled; no live UI, real-history inference or answer-quality assessment was performed.

Reproduce ordinary checks with `swift test`. For native synthetic checks:

```sh
JOURNAL_EMBEDDING_MODEL="$PWD/Models/Qwen3-Embedding-0.6B-Q8_0.gguf" \
JOURNAL_GENERATION_MODEL="$PWD/Models/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf" \
swift test --filter 'MemoryRelevanceNativeTests|EmbeddingCacheTests/testNativeCachedAndTransientResultsMatch|SemanticRetrievalTests/testNativeSyntheticSemanticRetrieval|LocalAnswerModelTests/testNativeRankedMemoryCandidatesFitActualTokenizer'
```

An optional `JOURNAL_MEMORY_EVALUATION_REPORT` absolute path exports only synthetic case numbers, selected/expected indices, scalar scores, counters and model identity. No text or vectors are included. New holdout cases, broader semantic coverage, answer grounding, and controlled cold/warm latency remain required before broader release-quality claims. Generate-time refresh adds an embedding verification/load/query cycle when eligible memory exists; its interactive latency has not been benchmarked here.
