# Remaining implementation roadmap

Status: proposed work, reviewed against source on 2026-11-05. [Current status](../STATUS.md) identifies what is already implemented. This replaces the earlier mixed memory/retrieval proposal; its original requirements remain in the [historical snapshot](../archive/MEMORY_AND_RETRIEVAL_PLAN_2026-11-05.md).

The detailed [prompt and context improvement plan](PROMPT_CONTEXT_IMPROVEMENT_PLAN.md) specifies memory ranking, question routing, evidence assessment, passage assembly and staged acceptance checks. It is proposed work, not current behavior.

## 1. Persistent retrieval cache

The core cache and app integration are implemented; see [operation and validation](../EMBEDDING_CACHE.md). The [original design](SQLITE_EMBEDDING_CACHE_DESIGN.md) remains the detailed rationale. Remaining promotion work is opt-in real-history measurement and interactive UI verification.

The next question should discover new Journal entries, reconcile source revisions, reuse compatible vectors across questions/restarts and embed only missing/changed passages. Keep current-original validation, atomic entry publication, independent cache reset, complete-manifest deletion reconciliation and cooperative cancellation.

Exit criteria: zero document re-embeddings for unchanged warm/restarted searches; new/edited/deleted/empty entries handled; incompatible/corrupt vectors cannot enter evidence; cancellation/reset cannot publish stale drafts; source permissions are not bypassed. Measure cold/warm latency and disk size before changing the current model-unloading policy or adding an ANN/vector extension.

## 2. Extraction quality and consolidation

Evaluate source-backed memory quality on broader, held-out English/Chinese fixtures and opt-in real examples. Classify validation failures instead of treating the aggregate rejection count as one known cause. Improve structured output reliability, distinguish conflicting statements and consolidate semantic duplicates while preserving dates, sources, negation, user corrections and forget decisions.

Exit criteria must cover unsupported claims, missed durable facts, conflicts, changed support, temporal meaning and correction preservation. More saved suggestions alone is not success. Automatic background remains visibly unconfirmed; do not reintroduce a blanket per-item gate or silently assert user approval.

## 3. Evidence selection

The current app already scans synced history semantically, considers 25 candidates and fits whole excerpts to a byte/full-token budget. Remaining work is paragraph/sentence-aware overlap, useful multiple passages from one entry, diversity, calibrated relevance/insufficient-evidence selection and held-out evaluation of the implemented question-aware memory selector.

Use labeled supporting-source recall and irrelevant-selection rates. Do not choose an arbitrary universal cosine threshold, force a fixed excerpt count, or let memory rewrite the question into a single biased search path. Add a reranker only if candidate recall is adequate and measured ranking quality justifies it.

## 4. Historical coverage

Implement explicit time/scope controls, then dated monthly summaries/coverage manifests if evaluation warrants them. Broad mood/trend questions need multiple periods and known gaps, not merely more nearest neighbors. Period summaries must track source revisions, completeness and original supporting entries; edits/deletions invalidate affected summaries.

Comparison questions need explicit event boundaries or user clarification when unknown. Distinguish journal-writing frequency from real-world event frequency. A bounded cancellable analysis fallback may cover missing summaries; partial work must be reported as partial.

Exit criteria: requested/available periods and gaps are visible; original examples support continuity and change; no claims of complete historical analysis from a small retrieval set. None of this period-summary/routing work is implemented today.

## Deferred

Autonomous tool loops, relationship graphs, proactive coaching, attachments, cloud inference and fine-tuning are outside the current implementation. Separate evaluation of background-memory-on/off answers is also needed before claiming that the profile improves real answer quality generally.
