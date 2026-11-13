# Embeddings and semantic retrieval

Current implementation, source-checked 2026-11-06. See [architecture](ARCHITECTURE.md) for the full pipeline and [SQLite cache operation](EMBEDDING_CACHE.md) for persistence and validation.

## Setup and model

From the project root:

```sh
Scripts/setup-llama.sh
Scripts/setup-embeddings.sh
```

The scripts download and verify these separate artifacts:

| Artifact | Pin | SHA-256 |
| --- | --- | --- |
| llama.cpp XCFramework | b12038 | `484ea8b06c2c41e37d3ea8c2d456d16c2fe62bf9987f0c609dd9443b3f6b89e3` |
| Qwen3-Embedding-0.6B Q8_0 | revision `370f27d7550e0def9b39c1f16d3fbaa13aa67728` | `06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439` |

The embedding weights are 639,150,592 bytes. They are separate from the 4B answer/extraction model and cannot generate prose. Discovery checks private Application Support Models, bundled Models, then checkout Models.

`LocalEmbeddingModel` serializes native inference on its actor. The engine uses LAST pooling, L2 normalization and a 2,048-token input context. The actual output dimension is read from the loaded model. Questions receive the Qwen retrieval prefix; document passages do not. Runtime loading verifies the actual weights against the pinned SHA-256 before native loading and exposes an embedding-space descriptor with the actual output dimension, processing signature and runtime revision. Query instructions and answer-model changes do not invalidate document vectors.

Sources: [Qwen embedding weights](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF), [llama.cpp](https://github.com/ggml-org/llama.cpp). Preserve the notices under `ThirdPartyNotices` when distributing artifacts.

## Current retrieval

- Preparation synchronizes metadata automatically before reconciliation. Explicit **Sync Apple Journal** also updates the cache. Explicit request date bounds are supported; natural-language date inference is not.
- All live entries in the successful source-scoped manifest are considered. Unchanged fingerprints reuse complete vectors; changed fingerprints read current bodies and may still reuse vectors when decoded text is identical. Selected originals are always reopened.
- Bodies are split into non-overlapping passages of at most 768 UTF-8 bytes, preferring whitespace boundaries without breaking Unicode scalars.
- Query and passage vectors are checked and normalized, then scored by cosine similarity. One best passage per entry survives. Score ties use stable entry identity.
- The default Assistant planner retains 25 candidates. The context builder selects a variable number of whole excerpts within its byte budget; generation applies the actual full-prompt token budget.

**Document vectors are persisted by default** in the independent private SQLite retrieval cache. Warm unchanged searches, including after restart, require zero document embeddings. Every question still needs one query embedding, model loading/verification, source metadata scanning and selected-original reads. Disabling reuse retains stored vectors and uses transient search. Model resources unload before answer generation and on cancellation/error.

There is no calibrated relevance cutoff. A larger candidate pool does not establish answerability or exhaustive trend coverage. Passage boundaries may lose cross-boundary meaning. Pages/entry reads are not an atomic view of the whole history. Cancellation is cooperative; an active native call cannot be interrupted immediately.

## API and checks

```swift
let embeddings = LocalEmbeddingModel()
try await embeddings.load(from: modelURL)
let passageVector = try await embeddings.embedDocument(text)
let questionVector = try await embeddings.embedQuery(question)
await embeddings.unload()
```

```sh
swift test
JOURNAL_EMBEDDING_MODEL="$PWD/Models/Qwen3-Embedding-0.6B-Q8_0.gguf" \
  swift test --filter SemanticRetrievalTests/testNativeSyntheticSemanticRetrieval
```

Checks use synthetic data: older Chinese evidence winning an English query over a newer unrelated entry, pagination beyond 50, edits without reindexing, deletion exclusion, dates, Unicode bounds, invalid vectors and cancellation. These establish mechanics, not broad retrieval quality. Earlier machine-specific timing/test counts are in the [archive](archive/README.md).
