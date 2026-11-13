# Local generation-model upgrade — 2026-11-05

Dated evaluation record. Model choice and measured results remain relevant; current memory activation/confirmation behavior is documented in [PERSONAL_MEMORY.md](PERSONAL_MEMORY.md).

## Selection

The selected upgrade is **Qwen3-4B-Instruct-2507 Q5_K_M**, compared with the previous **Qwen3-0.6B Q8_0**. The larger weights are 2,889,513,696 bytes, versus 639,446,688 bytes for the baseline. Both remain entirely local; the embedding model is unchanged.

The 4B instruction model is a practical first upgrade for local use: it is substantially larger while keeping the weights under 3 GB, uses the existing Qwen3/llama.cpp path, and has a dedicated non-thinking chat template. Its advertised multilingual instruction-following improvements justify evaluation, not a claim of adequate memory extraction by themselves.

Primary sources:

- [Qwen's original model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [GGUF quantizer/distributor and quantization options](https://huggingface.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF)
- [Previous official 0.6B GGUF](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF)

The new GGUF is pinned to revision `ae44f08e1392f39c0e474af10c3ff8355c8b6688`, SHA-256 `66713ce35a58a82fe87642d4ec13425bf9b9a46800fff5c49a665ef5701439dc`. File size and the full checksum must match before discovery can use the published file. This is a third-party quantization of Qwen's Apache-2.0 model; attribution is in [model sources and licenses](ThirdPartyNotices/GenerationModels.md).

## Evaluation method

`ModelExtractionEvaluationTests` runs both actual models sequentially against the same 12 synthetic fixtures: ten positive cases and two negative cases, spanning English/Chinese goals, preferences, relationships, current circumstances, changed preferences, and transient observations/moods that should produce no memory. The same extraction instructions, 8,192-token context, 768-token output reserve and greedy sampler are used, with each model's proper chat template.

The exact-pattern shortcut is disabled. A positive hit requires the expected category and an expected source anchor in the statement or its exact supporting quote. Invalid JSON, unsupported quotes and inference errors count as misses. Source-quote validity, negative-case empty output and latency are reported separately. These are small labeled functional cases, not a broad recall/precision benchmark. Synthetic statement/quote details are reviewed separately; real journal content is never written to diagnostics.


## Results

The final comparison passed with exact-pattern matching disabled:

| Measurement | 0.6B Q8_0 | 4B Instruct Q5_K_M |
| --- | ---: | ---: |
| Expected positive cases found | 0/10 | 10/10 |
| Valid structured/source-backed outputs | 12/12 | 12/12 |
| Negative cases correctly left empty | 2/2 | 2/2 |
| Returned candidates | 0 | 13 |
| Load/verification time | 0.54 s | 2.31 s |
| Inference for all 12 fixtures | 1.16 s | 16.96 s |

The baseline's low latency comes from returning empty arrays; it did not perform equivalent useful extraction. The larger model is slower and materially more useful on this suite. All thirteen larger-model statements were manually checked against their synthetic inputs; quotes were literal and the statements were supported.

Initial 4B runs scored 8/10 with one invalid output, then 9/10 after clarifying categories/quote copying. The remaining miss was an interview-preparation goal, resolved by distinguishing ongoing preparation from transient one-off activities. Therefore these cases also served as prompt-development fixtures: the final 10/10 is a regression-suite result, not a held-out accuracy estimate.

All fifteen native generation tests passed with the 4B weights, including grounded citations, repeated/streamed generation, cancellation/reuse, memory-based answering, raw model comparison and actual tokenizer budgets. The ordinary suite passed 69 tests with six opt-in checks skipped. Strict formatting, signed normal app compilation and deep signature verification passed. Peak resident size for the full native test command was about 7.13 GB (including repeated lifecycle tests and both models), with zero process swaps; it is not a measurement of steady-state app memory.

## Full-history extraction limitations

A development run completed the source scan and kept valid, source-linked results. Some model outputs failed validation and remain retryable. The failure counts group together malformed output, unsupported quotes and other validation errors. The synthetic comparison above is the basis for the model selection.
