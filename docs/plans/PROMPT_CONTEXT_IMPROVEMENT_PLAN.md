# Prompt and context improvement implementation plan

Status: partially implemented. Current behavior is documented in [Prompt and output design](../PROMPT_AND_OUTPUT_DESIGN.md).

## Objective

For each question, select relevant personal background and current original evidence, preserve time and source meaning, and fit the actual model input budget. Every selection should have an inspectable reason. Similarity, user confirmation and model judgment are signals; none is proof of factual truth.

The first release covers explicit question scope, query-aware memory ranking, source-preserving excerpts and evidence-first budget allocation. Automatic interpretation and a model-based evidence judge are subsequent, separately measured additions.

## 1. Establish the evaluation baseline before tuning

Create a versioned bilingual synthetic corpus with dates, supporting entry IDs and memory IDs. Start with 60 development cases and 40 held-out cases; these are proposed fixture counts, not existing evaluation results. Freeze the held-out cases before changing prompts, weights or cutoffs. Keep paraphrases of a scenario in the same split to prevent leakage.

Include targeted lookup, explanation, timeline summary, before/after comparison, ambiguous dates, no answer, irrelevant confirmed memories, useful unreviewed memories, negation, reported speech, contradictory memories and edits/deletions. Include broad questions whose evidence is distributed over time and strong lexical matches that do not answer the question.

Record the existing pipeline's supporting-entry recall, irrelevant-memory inclusion, unsupported factual claims, requested-period coverage, final tokenizer counts, and median/p95 prepare/generate latency. Evaluate direct factual support separately from whether an interpretation sounds plausible. Use blinded human review for ambiguous answer judgments; a model grader alone is insufficient.

Implementation owner: existing Core/Generation test suites plus a bounded synthetic evaluation runner. No private journal text, extracted memories or model answers enter routine logs. Real-history evaluation remains explicit opt-in.

## 2. Know what kind of question is being asked

### First release: explicit, inspectable scope

Extend the existing retrieval plan with a task intent and resolved scope. Add Assistant controls for Auto / Find / Reflect / Summarize period / Compare periods, plus date bounds when applicable. Explicit user selections override automatic suggestions. Do not duplicate planning in the view and retriever.

| Intent | Meaning | Retrieval strategy |
| --- | --- | --- |
| Find | Locate a fact, event or specific mention | Semantic candidates, entity/date constraints and original-text validation |
| Reflect | Interpret possible connections or causes | Direct relevant statements plus relevant background; interpretations stay qualified |
| Summarize period | Describe a specified period | Bounded date buckets with evidence from across the period and a coverage manifest |
| Compare periods | Describe a difference across two scopes | Separate retrieval/coverage for each side, followed by comparison |
| Clarification needed | Essential scope or referent is missing | Ask one specific question; do not invent the event boundary or period |

A bounded timeline sample supports a sample-based summary. It is not an exhaustive period summary. Coverage metadata must say how many entries exist, were examined, were selected, and could not be read; a month containing no entries is not evidence that nothing happened.

### Subsequent addition: automatic interpretation

Use one bounded structured-output call with the existing verified local answer model, not a growing collection of keyword regexes. Its inputs are the exact question, current date, local timezone and explicit controls. Its outputs are an enum intent, topic, requested scope, date expressions and optional clarification. It must not infer personal facts from memory or rewrite away the original question.

For example, on 2026-11-06 in Asia/Shanghai, “How was my mood last month?” proposes a period summary with local dates [2026-10-01, 2026-11-01). Swift resolves calendar expressions and timezone boundaries; model-supplied absolute dates must be validated. “Before and after I changed jobs” needs a known or user-supplied event boundary, not a guessed date.

Decode into typed Swift values. Validate enums, date order, range bounds and number of requests. Do not treat a self-reported confidence score as calibrated. Invalid output has a real bounded recovery path: retain the original semantic question, visibly mark scope unresolved and offer manual scope/clarification; do not label it a successful temporal analysis.

The planner call requires loading/unloading generation weights before embedding work. Measure this overhead before making Auto the default. Manual scope remains the low-latency supported path. If measured performance is unacceptable, do not ship an unused classifier behind a misleading fallback label.

Acceptance: explicit choices always win; deterministic calendar tests cover month/year boundaries, local midnight and daylight-saving transitions; ambiguous event boundaries trigger clarification; model-planning intent/date accuracy is measured on held-out cases.

## 3. Select memories relevant to the question

Implementation note, 2026-11-06: the first query-aware selector, revision-aware memory-vector namespace and Generate refresh are implemented. See [evaluation](../MEMORY_RELEVANCE_EVALUATION.md). The initial cutoff is development-only; two broad-question misses remain, no empirical near-tie relevance band is enabled, and held-out release gates remain outstanding.

Replace “serialize highest-priority memories first” with the following single pipeline:

1. Read enabled, eligible records. Preserve user corrections, forget decisions and existing source-validation semantics. Exclude outdated/clarification records and automatic facts without current support.
2. Embed the original question and each candidate memory statement using the existing embedding model's query/document methods. Keep the question independent of selected memory so background does not bias the only retrieval path.
3. Rank by cosine similarity to produce candidates. After calibrating on development fixtures, reject candidates that do not meet the relevant-memory operating point. Similarity is a ranking signal, not a probability. Allow zero selected memories.
4. Within empirically indistinguishable relevance bands, prefer user corrections and confirmed facts, then time relevance and recency. Band width/cutoff are development-set choices locked before held-out evaluation, not arbitrary universal constants.
5. Deduplicate exact normalized statements. Remove overlapping information from the selected set only when equivalence is supported; do not merge negations or conflicting statements simply because their embeddings are close.
6. Serialize only the selected records. Keep dates and review/origin metadata. Apply the shared token fitter after selection rather than irreversibly discarding candidates at the old profile byte cap.

Example: for “What changed in my relationship with my father?”, a newer confirmed tea preference is excluded while a supported unreviewed family memory may be included. For “What did I eat on Tuesday?”, no durable memory may be necessary.

Cache memory embeddings under an explicit memory namespace in the existing embedding-cache infrastructure. Identity includes memory UUID, statement revision and embedding-space descriptor. Do not impersonate memories as Journal entries or validate them through Journal UUID reads. Add a versioned schema migration and tests; retain existing cached document vectors. Recompute changed statements only, invalidate forgotten/deleted memories, and apply the existing sensitive-vector storage/reset policies. Avoid a second standalone cache engine.

Separate explicitly configured response preferences from autobiographical facts. Do not silently reinterpret every existing `.preference` memory as an instruction; “likes tea” and “prefers short answers” have different meanings.

Acceptance: unrelated confirmed facts cannot win solely through confirmation; relevant automatic facts remain visibly unconfirmed; memory-off/empty states work; conflicts and user corrections survive; unchanged warm requests do not re-embed every memory. Held-out evaluation must show fewer irrelevant memories without losing supporting background or increasing unsupported claims.

## 4. Decide which evidence actually supports an answer

Implementation note, 2026-11-09. Cached and transient excerpts now share identity, date, revision and UTF-8 range checks before generation. The answer instructions distinguish direct support from related context and ask the model to preserve negation, attribution and conflicts, qualify interpretations, and state gaps for trends and comparisons.

The native synthetic v1 baseline retained the 25-entry candidate limit. It found both labeled interview entries (including counterevidence) and the labeled dinner entry before and after draft fitting. The no-support question still received 25 candidates, illustrating why similarity alone cannot establish support. These three queries are a smoke baseline. They do not measure held-out precision, broad temporal recall, or the effect of expanding passage boundaries. In a separate four-case smoke check, the pinned Qwen3 4B answered the direct, counterevidence, related-only and empty-evidence prompts as expected. The optional judge remains gated on broader evaluation, and a coverage manifest depends on the explicit scope work in section 2.

The [evidence pipeline development evaluation](../EVIDENCE_PIPELINE_EVALUATION.md) extends the smoke baseline and separates entry recall, passage retention, prompt fitting and answer verdicts.

Use three distinct assessments rather than one opaque “strength” score:

| Assessment | Determined by | What it establishes |
| --- | --- | --- |
| Source validity | Swift checks identity, deletion, revision, dates and UTF-8 locations against originals | The excerpt is current and faithfully copied |
| Relevance/directness | Retrieval ranking; later an evaluated bounded evidence judge | Whether the excerpt addresses this question and directly supports a candidate statement |
| Coverage | Requested scopes and corpus/selection manifest | Which periods or sides of a comparison were represented |

“Strong evidence” means a current, traceable excerpt directly supporting the specific claim within the requested scope. It does not mean that all claims in the entry are objectively true. “I felt nervous about tomorrow's interview” directly supports interview-related nervousness; “I bought interview clothes” is related context and does not establish anxiety. “I was not worried about the interview” is relevant counterevidence, not a poor match to discard.

First retain the existing 25-entry candidate baseline and measure supporting-source recall. Fix candidate recall and passage boundaries before adding a reranker. Do not rank confirmed memories as equivalent to original supporting evidence.

If recall is adequate but false-positive selection remains material, add an optional evaluated judge in `JournalGeneration`. Use the already-loaded answer model during Generate, before the answer, to avoid a separate reranker model. Input is the original question and bounded batches of original excerpts. Each output identifies an allowed candidate, labels it direct/context-only/unrelated, records support/contradiction when applicable, and returns a short exact supporting span. Swift verifies every candidate ID and literal span. Batch size is determined by actual input/output budgets; do not stuff all candidates into one unbounded judgment prompt.

Judge labels remain fallible. Malformed output must not manufacture a high-confidence result: retain validated candidates as unassessed, disclose insufficient assessment if material, and use the existing qualified-answer policy. Promote the judge only if it improves held-out support precision without unacceptable recall or latency loss. Report the additional calls and tokenizer use.

Acceptance: valid exact anchors; no invented IDs/quotes; unrelated lexical matches rejected; direct negative/counterevidence retained; no-evidence answers acknowledge missing support. Every trend/comparison answer has explicit coverage, not just a high similarity score.

## 5. Improve the original text supplied as evidence

Implementation note, 2026-11-09. Cached and transient retrieval expand the winning passage to a bounded exact range from the same original. Both split-passage misses were recovered in the unchanged bilingual development fixture. Indexed passage boundaries, embedding identity and stored vectors are unchanged. Multiple noncontiguous excerpts and temporal diversity remain separate work. See [the comparison](../EVIDENCE_PIPELINE_EVALUATION.md#bounded-expansion-2026-11-09).

Change excerpt assembly before changing the indexed passage format:

1. Keep the cached embedding passages and their format initially. For each selected location, reopen the current original and expand within the same entry to complete nearby sentences/paragraphs, subject to the final token budget.
2. Use native sentence segmentation with a bounded Unicode-safe fallback for punctuation-free long text. Preserve exact source bytes; do not paraphrase or normalize before computing UTF-8 ranges.
3. Include surrounding text when it supplies the subject, negation, reported speaker, explanation or date qualification. Merge overlapping ranges from the same current revision so context is not repeated.
4. Recompute and validate references for the expanded range. If one entry needs two noncontiguous excerpts, introduce an explicit passage identity separate from entry identity and update deduplication, validation and UI mappings together. Do not reuse entry-only deduplication that silently discards the second excerpt.
5. For temporal tasks, select across requested buckets/sides before filling remaining slots by similarity. Keep contradictions visible rather than choosing only mutually agreeable passages.

Only change the cached passage splitter if evaluation shows that expansion cannot recover missing candidates. A splitter change must update the embedding-space processing version and invalidate/rebuild incompatible vectors; otherwise old positions and newly computed passages would disagree.

Acceptance: English/Chinese punctuation, emoji, combining characters, long punctuation-free entries, overlapping ranges, multiple passages, negation, reported speech and concurrent edits are covered. Excerpts and reference locations must match original bytes exactly. Expansion must improve supporting-context retention without increasing unsupported claims.

## 6. Fit one final context and strengthen the answer contract

Retain bounded candidate collections until final tokenizer fitting. The final fitter now drops ranked background records before original excerpts under input pressure. A native tokenizer regression verifies that a directly supporting excerpt and the complete question survive when dropping background alone makes the prompt fit. For comparisons, reserve evidence for each available side; if both cannot fit, report insufficient coverage instead of silently losing a side.

Keep the native context/output limits initially. Measure full formatted tokens, including escaping and headers. Do not maximize token use for its own sake. Token counts, final selections, omission reasons and coverage shown in the preview must reflect the actual final input. Revalidate originals before generation; selected memory must be refreshed through the same query-aware selection policy.

Keep the existing untrusted-data and ID protections. Add brief rules to distinguish explicit statements from interpretations, respect dates and conflicting statements, avoid inferring a recurring pattern from one event, and avoid treating missing entries as missing real-world events. Pass resolved scope and actual coverage as structured data. Add one compact example only when a measured failure justifies its cost.

Acceptance: short and oversized questions, empty evidence/memory, relevant evidence competing with irrelevant memory, comparison coverage, escaping expansion and budget exhaustion. No silent question truncation or arbitrary loss of the required comparison side.

## 7. Implementation sequence and ownership

| Change set | Deliverable | Main code ownership |
| --- | --- | --- |
| A | Frozen evaluation fixtures/baseline; typed plan/coverage contracts; explicit intent/date controls | Core prompt contracts and `JournalQueryPlanner`; App view/view model |
| B | Query-aware memory candidate ranking and revision-aware vector reuse | `PersonalMemoryStore`, existing embedding cache infrastructure, `JournalPromptService` |
| C | Source-preserving range expansion, passage identity where needed, temporal diversity/coverage | Retrieval implementations, `JournalPassages`, context builder and preview |
| D | Evidence-preserving actual-token fitting and revised answer instructions | `LocalAnswerModel`, `QwenPromptFormatter`, `JournalPromptAugmenter` |
| E | Automatic structured planning, promoted only after intent/latency evaluation | `JournalGeneration` implementation using Core plan types; service orchestration |
| F | Conditional evidence judge if ranking evaluation justifies it | `JournalGeneration`, reused by Generate workflow |

No autonomous agent loop, additional model family, blanket user-confirmation gate, Python runtime integration, or persistent conversation memory is required for these change sets. Follow-up chat state and monthly summaries are separate product work.

The service coordinates model lifetimes; Core owns typed rules and retrieval/persistence contracts without llama.cpp; view models own display/request state. Extend existing responsibilities before creating new layers. Each change set must update its callers, behavioral tests, build references and current design docs; replace obsolete paths rather than preserving unused alternatives.

## 8. Release gates

Run unit/synthetic checks for each change set, native model evaluation where semantics/tokenization change, and a macOS app build for changed application wiring. Re-run the held-out suite only for release evaluation, not iterative tuning.

Required deterministic gates: zero invalid source ranges, invented accepted IDs/quotes, stale references, privacy-log leaks or budget violations in fixtures; cancellation and cache migration/reset preserve supported behavior. Routing must honor explicit scope. Semantic changes must improve their target metric without a measured regression in supporting-source recall, unsupported claims or temporal coverage; report results per question type, not only an aggregate score.

Publish baseline versus candidate token counts and prepare/generate median/p95 latency, including extra model loads/calls. Keep slower automatic planning/judging opt-in until the latency/quality tradeoff is acceptable. Do not describe the plan as implemented or quality improvements as established until these gates have been run successfully.
