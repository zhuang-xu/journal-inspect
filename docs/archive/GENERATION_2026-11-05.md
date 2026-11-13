> Historical snapshot through 2026-11-05. Superseded by the [current documentation](../README.md). These claims describe earlier stages and are not current product instructions.

# Local Qwen answer generation

## Preferred model upgrade — 2026-11-05

The preferred generation and memory-extraction model is now **Qwen3-4B-Instruct-2507 Q5_K_M**. The pinned GGUF is 2,889,513,696 bytes (about 2.9 GB), distributed by bartowski from Qwen's Apache-2.0 model. The existing Qwen3-0.6B Q8_0 remains supported for explicit comparison. Embeddings still use the separate Qwen3-Embedding model.

Run `Scripts/setup-generation.sh` to download the exact pinned larger weights. The setup-only helper uses resumable, range-validated downloads and checks the full SHA-256 before publishing the model file. The Swift app has no Python runtime dependency and performs no automatic network inference or weight downloads. See [model sources and licenses](../ThirdPartyNotices/GenerationModels.md) for revision, file size, checksum, source and licensing.

Discovery prefers 4B across known private, bundled and checkout locations, then locates the legacy baseline if 4B is absent. The UI names the selected model. Loading verifies the entire file against the explicit model registry and chooses the corresponding chat template. Qwen3-4B-Instruct-2507 uses the assistant generation prefix without a thinking block; the old 0.6B model retains its empty thinking prefix. The native context remains 8,192 tokens with 768 reserved for output, independently of the model's advertised context capacity.

Memory extraction now uses the actual selected model for every passage: the earlier narrow exact-pattern shortcut is not part of the production extraction path. The processing version includes model identity so incremental updates cannot treat a different model's previous results as current. Explicit Build suggestions reprocesses all indexed entries as before. Source validation, user edits and suppression decisions are preserved. Built automatic memories are now available as background when enabled; individual confirmation is optional.

The upgrade targets this Mac's Apple M3 Pro and 18 GiB unified memory. It is a practical local step from 0.6B, chosen for instruction following, bilingual text comprehension, existing llama.cpp compatibility and a moderate download size. Native evaluation passed the selected regression suite; detailed results and the pending real-history verification are recorded in MODEL_UPGRADE_EVALUATION.md. Larger parameter count alone is not proof of adequate personal-memory quality.

The following sections describe the historical 0.6B implementation; preferred-model details above supersede the old single-model paths and pinning claims.

The app now runs question → recent journal retrieval → bounded context → local llama.cpp/Qwen answer. No server, cloud API or Python runtime is involved. Retrieval policy is still up to five recent indexed entries; generation does not make retrieval semantic or adaptive.

## Models have separate jobs

- **Qwen3-Embedding-0.6B Q8_0** produces vectors for future semantic retrieval. It cannot generate an answer.
- **Qwen3-0.6B Q8_0** is the chat/generation model used here. It is a different set of weights, despite having a similar name and size. This small baseline may produce weak answers; verify claims and citations against the supplied entries.

The answer model is from [Qwen's official GGUF repository](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF), pinned to revision `23749fefcc72300e3a2ad315e1317431b06b590a`. File: `Qwen3-0.6B-Q8_0.gguf`, 639,446,688 bytes. SHA-256: `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`. Apache 2.0 license; retain [Apache 2.0 notice](../ThirdPartyNotices/Apache-2.0.txt) when distributing weights. The llama.cpp runtime remains b12038, MIT licensed.

## Run

1. Run `Scripts/setup-generation.sh` to download and verify the answer model. Existing llama.cpp setup is described in EMBEDDINGS.md.
2. Open the app, sync Apple Journal, and select the **Assistant** tab.
3. The app automatically finds `Models/Qwen3-0.6B-Q8_0.gguf` in this checkout when launched from Xcode. It also checks `~/Library/Application Support/JournalInspect/Models` first, then the app’s bundled `Models` folder. Use **Choose Qwen model…** only to override discovery. Model selection is kept in memory for this app session; weights are verified and loaded automatically when you generate an answer.
4. Enter a question, choose **Prepare context**, review the optional journal-context disclosure, then choose **Generate answer**.
5. Use **New question** to start again, or **Edit question** to revise the current question. **Stop**, synchronization and closing the view invalidate outstanding results. Clear/sync/view close also remove the question, evidence preview and answer from app state.

Model selection is limited to these pinned weights by a streaming SHA-256 check at load time. Selecting the embedding model, another GGUF, or a corrupt download is rejected before native loading. The app does not automatically download weights or change system permissions. Weights are ignored by Git.

## Code boundaries

- `Sources/JournalCore/Data`: read-only Journal access and metadata persistence, unchanged.
- `Sources/JournalCore/Prompt`: retrieval/context contracts and augmentation; no llama dependency.
- `Sources/JournalLlama`: shared one-time backend initialization and suppression of native diagnostics, used by embeddings and generation.
- `Sources/JournalGeneration`: actor-owned model lifecycle, pinned-model verification, Qwen3 prompt formatting and native token generation. Implements `JournalAnswerGenerating`.
- `App/PromptViewModel.swift` and `App/PromptView.swift`: prompt and answer UI, separate from reader/browsing state.

The UI generates from the reviewed `AugmentedPrompt` directly; `JournalAssistant` also accepts this same model when a host wants the combined augmentation-and-answer API.

Qwen3 is formatted using ChatML with an empty `<think>...</think>` assistant prefix to select non-thinking mode. User-supplied control-token spellings beginning `<|` are escaped before tokenization. This protects role boundaries, but does not guarantee resistance to natural-language prompt injection. Non-thinking generation uses greedy decoding for a deterministic baseline; decoding policy may need tuning for better answer quality. Citations are model-generated text, not verified references; check them against the context's citation IDs.

## Resource and privacy limits

The native context is 8192 tokens. Input is capped at 64 KiB and tokenized with 768 tokens reserved for output. Oversized input is rejected without truncation. The context builder's earlier byte budget is independent of this final model-token check. Generation stops at the model's end token. If it reaches 768 output tokens, the UI retains the partial answer and labels it incomplete with a length-limit error. Text now appears progressively as llama.cpp generates it; the answer view follows the latest output. Model checksum verification/loading and prompt evaluation still happen before the first text appears.

The model is loaded for each answer and unloaded on success/error. KV memory is cleared before and after inference, including cancellation/failure. Cancellation is checked during checksum reads, between prompt batches (512 tokens) and each generated token. A single native model-load/decode call cannot be interrupted; cancelled UI work is discarded immediately but cleanup waits for that call to return.

No questions, journal bodies, evidence, KV state, answers or model diagnostics are saved by this feature. Only model weights are downloaded. App memory release is not secure erasure and cannot prevent OS swap/crash capture. The metadata database remains body/title-free. Existing Apple Journal private-schema, Full Disk Access and source-availability limitations still apply.

## Tests

`swift test` runs synthetic lifecycle, wrong/missing model, cancellation and prompt-format/control-token tests along with existing suites. To run native generation with synthetic text only:

```sh
JOURNAL_GENERATION_MODEL="$PWD/Models/Qwen3-0.6B-Q8_0.gguf" swift test --filter LocalAnswerModelTests
```

The native test checks a synthetic journal answer and citation, streamed/full-answer equivalence, multiple progressive snapshots, cancellation followed by reuse, oversized-input rejection and repeat inference after KV cleanup. Unit tests also verify UTF-8 characters split across token pieces and stream error propagation. A separate arithmetic quality probe answered “2 + 2” incorrectly with “2” in non-thinking mode, including greedy decoding. This is a known limitation of this small baseline, not a correctness guarantee from passing integration tests. No live Journal content is needed. The signed app's real Journal access and new UI interaction need separate manual verification.

Verified 2026-11-03: model checksum matched; final native-enabled SwiftPM run passed 42 tests with one live Journal test skipped. Synthetic grounded generation included the expected activity and citation, repeated deterministically, and rejected oversized input. The existing embedding inference check also passed after backend extraction. The macOS app compiled successfully with signing disabled; the new UI was not interactively exercised. Native inference checks ran with normal host Metal access because the restricted execution environment could not create a GPU context.

## Streaming API

`LocalAnswerModel` implements `JournalAnswerStreaming.streamAnswer(_:)`, returning an `AsyncThrowingStream<String, Error>`. Each element is the entire text so far, not a token delta: replace the displayed answer with each snapshot. Only the latest pending snapshot is buffered, so slow UI consumers cannot build an unbounded queue or lose text. UTF-8 token fragments are held until they form complete characters. A final trimmed snapshot is sent before successful completion. Stream errors mark partial text as incomplete; the original `answer(_:)` API still returns a complete answer or throws.

Cancelling the consuming task terminates the stream and cancels its native producer. Cancellation remains cooperative between native calls. The producer runs synchronously on the model actor so unloading/reloading cannot free resources during an active decode. The app checks a request identifier on every update; cancelled/cleared requests cannot restore old text. Cancel clears the answer; failures retain it with an incomplete label; Clear/sync/view close remove it. No streamed text is persisted or logged.

Streaming verification: final native-enabled run passed 44 tests, one live Journal test skipped, with zero failures. It verified multiple progressive updates, final/full-answer equivalence, Unicode buffering and cancellation followed by model reuse. The app build and formatting checks passed; visual interaction remains unverified.

## Visible activity states

While work is active, the journal assistant displays a progress panel with a spinner, a short explanation and total elapsed seconds. It distinguishes reading journal context, checking the model file, loading Qwen weights, preparing inference resources, processing the prompt, and writing the streamed answer. Loading transitions come from the model actor before verification, native weight loading, and native context creation; no percentage or remaining-time estimate is fabricated. Short stages may pass too quickly to be seen. Delayed callbacks are ignored after cancellation/completion and cannot move the UI back from generation to loading. Success, cancellation and errors replace the activity panel with the existing result message.

## Assistant layout

Assistant and Entries are separate tabs. The assistant uses a multiline question field and one prominent action per stage: Prepare context, then Generate answer. Local-model selection lives in a compact menu. Journal context is shown as readable evidence with citation IDs rather than raw prompt JSON. A vertical divider lets you resize the question/context area and the answer pane; the composer scrolls when space is limited. Streamed answers follow new output while you are at the bottom and preserve your position when you scroll up. Sync history is available under Journal sync details in the header. Processing remains entirely local with the existing memory-only content lifecycle.


## Budgeted evidence and readable answers — 2026-11-05

The default semantic planner now requests a pool of up to 25 ranked entry excerpts across all synced dates. The context builder selects whole excerpts within its byte budget, and generation checks the full formatted request with the actual model tokenizer. Five is no longer an app-level excerpt target. A larger pool is not an exhaustive trend/coverage analysis or a calibrated relevance cutoff.

Private source and memory IDs stay in the host-side mapping and are removed from model-facing structured metadata. Product instructions request natural references to source dates and prohibit internal-ID output or an ID appendix. The evidence panel displays dates and excerpts. The answer presenter additionally suppresses legacy citation-ID appendices during streaming and strips bracketed internal references while preserving ordinary prose and non-internal references.


Live verification of the revised mood request completed with 11 selected excerpts and 17 background items after model fitting. The completed answer contained no raw UUIDs or citation-ID appendix. The ordinary suite passed 76 tests (six opt-in checks skipped), and fifteen native generation checks passed. Raw ID removal applies to the model-facing metadata; host-side source identities and dates remain available for review. Explicit test/API instructions may still request human-readable references; the product default does not request internal IDs.
