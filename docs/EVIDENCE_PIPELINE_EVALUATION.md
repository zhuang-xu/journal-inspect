# Evidence pipeline development evaluation

Development v1 uses 14 controlled probes against a 40-entry synthetic Apple Journal store. The bilingual fixture includes factual lookup, negation, reported speech, misleading lexical overlap, comparisons across entries, a missing comparison side, a contradiction, and two answers whose anchors occur in different passages of the same entry. Each answerable probe has labeled entry dates and exact UTF-8 spans.

The test calls the existing Assistant planner, cached retriever, augmenter, native tokenizer fitter and answer model. Retrieval receives the original question. Only the generation prompt appends the grading request for one English label, Yes, No or Unknown. The evaluator records entry recall, exact-span survival through each stage, formatted input tokens, stage latency and the verdict category. A correct label with a missing anchor is tracked separately from a grounded verdict. An unparseable label is ungraded. The test logs only synthetic case IDs and metrics.

Run from the project directory with the pinned local weights and Metal access:

```sh
JOURNAL_EMBEDDING_MODEL="$PWD/Models/Qwen3-Embedding-0.6B-Q8_0.gguf" \
JOURNAL_GENERATION_MODEL="$PWD/Models/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf" \
swift test --filter testNativeEvidencePipelineDevelopmentV1
```

The cold prepare measurement includes indexing and building the cache. The remaining prepare measurements reuse it. Generation timing measures the answer call after the model is loaded and excludes earlier validation and fitting. The test uses a fixed corpus, no personal memory and no live Journal data. This is a controlled development baseline. Open-ended claim quality, held-out precision and explicit period coverage require separate evaluation.

## Native baseline, 2026-11-09

All 14 labeled supporting-entry occurrences appeared among the 25 candidates. The chosen excerpts contained 16 of 18 required spans, and all 16 survived both context fitting stages. The English passport and Chinese notebook probes each lost one required span when retrieval chose a single passage from the right entry.

The pinned Qwen3 4B returned nine grounded verdicts and three correct abstentions on unanswerable probes. It also abstained on the two answerable probes with missing spans. There were zero incorrect factual verdicts and zero ungraded labels in this run.

| Probe | Supporting entries retrieved | Exact spans in final input | Verdict |
| --- | ---: | ---: | --- |
| `lookup-en` | 1/1 | 1/1 | Grounded |
| `lookup-zh` | 1/1 | 1/1 | Grounded |
| `negation-en` | 1/1 | 1/1 | Grounded |
| `negation-zh` | 1/1 | 1/1 | Grounded |
| `related-en` | 0/0 | 0/0 | Correct abstention |
| `related-zh` | 0/0 | 0/0 | Correct abstention |
| `attribution-en` | 1/1 | 2/2 | Grounded |
| `attribution-zh` | 1/1 | 2/2 | Grounded |
| `comparison-en` | 2/2 | 2/2 | Grounded |
| `comparison-zh` | 2/2 | 2/2 | Grounded |
| `missing-side-en` | 0/0 | 0/0 | Correct abstention |
| `split-en` | 1/1 | 1/2 | Abstained with missing span |
| `split-zh` | 1/1 | 1/2 | Abstained with missing span |
| `conflict-en` | 2/2 | 2/2 | Grounded |

The formatted inputs used 1,044–1,123 tokens. Cold prepare took 825 ms. Warm prepare median/p95 was 60/64 ms. The answer call median/p95 was 1902.5/1994 ms. These are single-run timings for the controlled probes.

The measured loss happened before draft fitting, at passage selection. The passage expansion follow-up uses this run as its comparison baseline.

## Bounded expansion, 2026-11-09

The same 14 probes used the same models, corpus, 25-candidate limit and prompt budgets. Cached and transient retrieval now assemble the excerpt around the winning passage using at most 1,280 original UTF-8 bytes. The indexed passages and vectors stay unchanged.

| Metric | Baseline | Expanded excerpts |
| --- | ---: | ---: |
| Supporting entry occurrences | 14/14 | 14/14 |
| Required spans in final input | 16/18 | 18/18 |
| Grounded verdicts | 9 | 11 |
| Correct abstentions | 3 | 3 |
| Abstentions with a missing span | 2 | 0 |
| Incorrect factual verdicts | 0 | 0 |

Both split-passage probes recovered the missing span and moved from Unknown to a grounded Yes. All other verdicts matched the baseline. With the same draft budget, six probes included one fewer excerpt and the Chinese split probe included two fewer excerpts. All previously retained required spans survived.

| Run | Input tokens | Cold prepare | Warm prepare median / p95 | Answer median / p95 |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 1,044–1,123 | 825 ms | 60 / 64 ms | 1902.5 / 1994 ms |
| Expanded | 1,044–1,123 | 862 ms | 60 / 63 ms | 1911.5 / 2033 ms |

The benchmark covers the observed passage-boundary failure and the other cases in this development fixture. Held-out precision, open-ended answers and period coverage remain unevaluated.
