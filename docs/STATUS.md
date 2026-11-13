# Current status

Source-checked: 2026-11-06. This is a concise implementation summary, not a new test run. Detailed development history is [archived](archive/STATUS_2026-11-05.md).

| Area | Implemented now | Remaining gap |
| --- | --- | --- |
| Journal access | Direct read-only SQLite, native RTF decoding, metadata sync, paging/dates/current bodies | Private Apple schema/permissions; searches are not a whole-history snapshot |
| Background memory | Private store, full/incremental extraction, source revisions, question-aware background selection and vector reuse, optional confirmation, edits/forget/reset | Imperfect model output; exact rather than semantic consolidation; no automatic conflict resolver; development cutoff misses two broad career-goal examples |
| Retrieval | Exhaustive cached semantic scan, best passage per entry, 25-candidate Assistant pool, budget-selected evidence | No calibrated relevance threshold or temporal coverage strategy |
| Generation | Verified 4B default, retained 0.6B comparison, model-specific formatting, streaming/cancellation and actual-token fitting | Finite context/output, model fallibility, no general grounding guarantee |
| Answer presentation | Source dates/excerpts in review, internal metadata IDs absent from model input, display guard against ID appendices | Does not add source navigation beyond existing evidence/memory controls or exhaustive citation validation |
| SQLite vector cache | [Implemented](EMBEDDING_CACHE.md): automatic freshness, private vectors, restart reuse, staged publication, reset epochs, current-original validation and controls | Controlled real-history timing and broader UI evaluation remain outstanding |
| Historical synthesis | No period-summary implementation | [Roadmap](plans/ROADMAP.md) |

## Architecture cleanup verification

The [2026-11-06 architecture cleanup](ARCHITECTURE_REVIEW.md) introduced explicit app composition, a retrieval application service, shared cancellable workers/private store file setup, and an evidence-reference deduplication fix. Its fresh package run discovered 101 tests: **94 passed, seven opt-in checks skipped, zero failures**. Recursive strict Swift formatting and the unsigned macOS Debug build passed. Development signing was unavailable to the execution environment; native inference and live UI checks were not rerun for this cleanup.

## Recorded verification

Cache verification after the live-button fix on 2026-11-06: **90 tests passed, nine opt-in checks skipped**, with no failures. A fractional-date regression failed before the fix and passed afterward; the separate native bilingual equivalence check previously passed. The normal development-signed Debug Xcode build, deep strict signature verification and changed-file formatting checks passed. Live **Prepare context** completed and enabled **Generate answer**. The unchanged refresh reused cached vectors. No controlled real-history cold/warm timing benchmark was run. Earlier native generation verification recorded **15 passed, one comparison check skipped**.

The [model-upgrade evaluation](MODEL_UPGRADE_EVALUATION.md) records a separate small bilingual model-comparison run: 4B found 10/10 labeled positive cases versus 0/10 for 0.6B, with 2/2 correctly empty negatives. The same cases informed prompt development, so this is not held-out general accuracy.

A development 4B build retained successful extractions and reported a partial failure. Rejected outputs remain retryable. See the [model evaluation](MODEL_UPGRADE_EVALUATION.md).

Live checks confirmed that answers could include background memory and excerpts within the prompt budget and that the display omitted internal identifiers.

## Immediate next work

Measure the implemented cache on opt-in real history and verify the controls interactively. Evaluate relevance selection and broad historical coverage separately; synthetic correctness checks do not establish general retrieval quality.

## Question-aware memory selection

The [selection evaluation](MEMORY_RELEVANCE_EVALUATION.md) records the first implemented question-aware profile and shared memory-vector namespace. Prepare and Generate use the same ranking policy; post-load revision/source checks reject changes. Relevant whole records reach the existing actual-token fitter without the old profile byte cap. Source validation, corrections, memory-off and dated conflicts remain supported.

Verification: 105 ordinary package tests passed, nine opt-in tests skipped; four separate native checks passed. The 20-case native development set retained 15/17 relevant statements and included zero labeled irrelevant statements at the initial 0.5 cosine cutoff. Two broad career-goal misses remain; this is not held-out accuracy. The development-signed macOS Debug build passed. No live UI, real-history inference, controlled latency or answer-quality evaluation was performed for this change.
