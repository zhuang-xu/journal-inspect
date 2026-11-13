# Local generation

Current implementation, source-checked 2026-11-05. Answers and memory extraction run locally through the Swift `JournalGeneration` actor and llama.cpp. There is no server or cloud transport.

## Supported models

| Use | Model | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| Preferred answer/extraction model | Qwen3-4B-Instruct-2507 Q5_K_M | 2,889,513,696 | `66713ce35a58a82fe87642d4ec13425bf9b9a46800fff5c49a665ef5701439dc` |
| Retained comparison model | Qwen3-0.6B Q8_0 | 639,446,688 | `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031` |

The preferred GGUF is a bartowski quantization of Qwen's Apache-2.0 model, not an official Qwen GGUF release. Exact revisions, source links and license attribution are in [model notices](ThirdPartyNotices/GenerationModels.md). Embeddings use a different model described in [EMBEDDINGS.md](EMBEDDINGS.md).

```sh
Scripts/setup-generation.sh
```

Setup uses bounded/resumable range downloads and validates the entire model size/checksum before publishing its file. Python is used only by this setup helper. The Swift app does not download weights automatically.

Default discovery prefers 4B across Application Support, bundled and checkout Models locations, then falls back to the existing 0.6B file if 4B is absent. **Journal Settings → Answer Setup** displays the selected model and allows manual selection. Loading hashes the actual file and accepts only registry-pinned weights. An arbitrary or corrupted GGUF is rejected; a filename alone is not verification.

## Formatting, budgets and output

See [Prompt and output design](PROMPT_AND_OUTPUT_DESIGN.md) for the complete preparation-to-display sequence and a synthetic formatted input.

The checksum-selected model configuration controls chat formatting. Qwen3-4B-Instruct-2507 ends with its non-thinking assistant prefix. The baseline retains an empty thinking block to select non-thinking mode. Greedy sampling gives deterministic regression behavior.

Native context is 8,192 tokens, with 1,536 reserved for journal answers and 768 for memory extraction. Fixed inputs over the 64 KiB input bound or remaining token capacity are rejected. Memory is capped at 900 actual model-facing tokens. The fitter drops whole background records before original excerpts when the formatted request exceeds the limit, preserving the complete question. These are app limits, independent of larger capacities advertised for the model.

`QwenPromptFormatter` keeps background, original evidence and the question identifiable; escapes control-token spellings; and removes source/memory IDs from structured model metadata. Product instructions request natural source dates and prohibit ID appendices. Internal mappings remain host-side. The evidence panel displays dates/excerpts. `JournalAnswerPresentation` additionally suppresses legacy citation-ID footer text and bracketed internal IDs during display.

These are formatting/grounding controls, not proof of truthfulness or resistance to all prompt injection. Automatically extracted background is explicitly fallible. Check meaningful claims against original evidence.

## Lifecycle and streaming

`LocalAnswerModel` owns the native engine. Each **Ask Journal** action loads/verifies the selected weights, fits the prompt and streams complete UTF-8 snapshots through a bounded latest-snapshot buffer. Slow consumers can skip intermediate snapshots; each snapshot replaces the preceding text.

The native KV state is cleared between answers and on error. Consumer cancellation cancels its producer; checksum reads, prompt batches and generation steps check cancellation. A single native operation may not stop immediately. App request IDs reject late updates, and unload waits for actor-owned work. Embeddings unload before answer generation.

Output-limit failures preserve displayed partial text with an incomplete status. Clear/new question, synchronization and view cleanup remove transient prompt/answer state. No answer or prompt history is persisted. OS swap/crash capture is outside a memory-erasure guarantee.

## Validation

```sh
swift test
JOURNAL_GENERATION_MODEL="$PWD/Models/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf" \
  swift test --filter JournalGenerationTests
JOURNAL_MODEL_EVALUATION=1 swift test --filter ModelExtractionEvaluationTests
```

The comparison command requires both pinned generation-model files. The current setup script downloads only the preferred 4B weights; it does not install the optional legacy baseline on a fresh checkout.

Tests cover verified loading/rejection, chat templates and role boundaries, metadata IDs absent from model input, real token budgets, grounded synthetic answers, streaming equivalence, cancellation/reuse and memory use. [MODEL_UPGRADE_EVALUATION.md](MODEL_UPGRADE_EVALUATION.md) records the measured bilingual development-suite comparison and partial real-history build. It must not be read as general extraction accuracy. Native tests need normal Metal access; ordinary tests skip opt-in inference.
