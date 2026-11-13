> Historical snapshot through 2026-11-05. Superseded by the [current documentation](../README.md). These claims describe earlier stages and are not current product instructions.

# Local embedding runtime

JournalEmbeddings is a separate Swift target wrapping the official llama.cpp XCFramework. Both SwiftPM and the Xcode app link it. There is no HTTP server or Python dependency. JournalCore defines the small JournalTextEmbedding protocol; JournalEmbeddings implements it. The assistant uses SemanticJournalRetriever to search synced history without persisting content or vectors.

## Setup

Run `Scripts/setup-embeddings.sh` from this checkout. It downloads and verifies pinned artifacts before using them:

| Artifact | Version | SHA-256 |
| --- | --- | --- |
| llama.cpp XCFramework ZIP | b12038 | `484ea8b06c2c41e37d3ea8c2d456d16c2fe62bf9987f0c609dd9443b3f6b89e3` |
| Qwen3-Embedding-0.6B-Q8_0.gguf | Qwen revision 370f27d7550e0def9b39c1f16d3fbaa13aa67728 | `06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439` |

Model size: 639,150,592 bytes (639 MB / about 610 MiB). Framework ZIP: 70,361,848 bytes. The model and framework are downloaded artifacts ignored by Git. The initial developer model lives at `Models/Qwen3-Embedding-0.6B-Q8_0.gguf`; a packaged app can later manage models under Application Support. Model weights contain no journal data.

Qwen is Apache 2.0 licensed; llama.cpp is MIT licensed. Preserve upstream license notices when distributing binaries. Sources: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF and https://github.com/ggml-org/llama.cpp.

## Verify

```sh
swift build
swift test
/usr/bin/time -l .build/debug/embedding-check Models/Qwen3-Embedding-0.6B-Q8_0.gguf
```

The check uses synthetic text only, requires relevant text to outrank unrelated text, checks repeat stability and rejects empty/oversized input. It prints aggregate status, not journal content. Native diagnostics are suppressed process-wide to prevent accidental text/token logging.

## Swift usage

```swift
import JournalEmbeddings

let embeddings = LocalEmbeddingModel()
try await embeddings.load(from: modelURL)
let passage = try await embeddings.embedDocument(text)
let query = try await embeddings.embedQuery(question)
await embeddings.unload()
```

The actor serializes access off the main actor. Query instructions follow Qwen's retrieval format; document text has no query prefix. LAST pooling and L2 normalization produce 1024-dimensional vectors. The native context is bounded to 2048 tokens, one sequence per call, with GPU offload requested through Metal. Long inputs are rejected, never silently truncated; chunking belongs in the future retrieval layer. Cancellation is checked before loading/inference; an in-flight native call is not interruptible yet. Loading a replacement releases the previous model first. Backend initialization is process-wide; model/context allocations are released by unload/deinitialization.

The wrapper writes neither text nor vectors. Future indexing must record the model checksum, dimensions, query instruction, decoder and chunking versions. Model changes require rebuilding embeddings. Embeddings remain private derived journal data even without a plaintext cache.

## Measured verification — 2026-11-02

On this M3 Pro / 18 GB / macOS 27.0.1 machine, both downloaded artifact SHA-256 hashes matched the pinned values. The model completed synthetic English and English-to-Chinese ranking, 1024-dimensional unit normalization, repeat stability, empty input and token-limit rejection checks. Elapsed time including model loading and the checks was 6.71 seconds (7.33 seconds process wall time). `/usr/bin/time -l` reported maximum resident set size 997,097,472 bytes (about 951 MiB) and peak memory footprint 428,279,368 bytes (about 408 MiB). These are different OS accounting metrics, not additive or a full measurement of all system/GPU memory; this was a short synthetic run, not a throughput benchmark.

SwiftPM: 33 tests discovered across both test bundles, one live Journal test skipped, no failures. The Xcode app built successfully with its existing development signing identity and the llama framework embedded. No real journal entries were read by the embedding verification and no vector index was created.

## Semantic retrieval — 2026-11-03

The Assistant's Prepare context action discovers the embedding model in the same fixed locations as the answer model (Application Support Models, bundled Models, checkout Models), loads it, embeds the question using the existing retrieval instruction, and scans every nondeleted indexed entry in 50-entry pages. Each current body is opened through the existing on-demand reader; missing/deleted entries are skipped and source identity checks still apply. New entries require synchronization first. Dates can be filtered through RetrievalRequest; natural-language date interpretation is not implemented.

SemanticJournalRetriever splits text into passages of at most 768 UTF-8 bytes, preferring whitespace boundaries and preserving Unicode scalars. This conservative bound fits the native byte-based tokenizer's 2048-token limit without introducing a tokenizer dependency into JournalCore. Passages do not overlap; cross-boundary context can be lost. Only the highest-scoring passage from each entry is eligible. Vectors are validated, normalized, and compared by cosine similarity; ties use stable source/entry identity. The retriever retains at most request.limit excerpts (default five), then the existing context builder applies its JSON byte budget. Citation IDs refer to the original entries. Instructions and UI explicitly describe excerpted, nonexhaustive evidence.

This first version performs a streaming exhaustive vector scan rather than retaining a vector index: embeddings are recomputed on every Prepare context action, and only the current page, passage vectors and selected evidence are held transiently. No body/vector cache, vector database, keyword extraction, network call or metadata schema change is introduced. Model resources are unloaded before answer generation and after errors/cancellation. Core has no llama.cpp dependency. Unavailable/missing weights produce an actionable UI error; there is no silent recent-entry fallback.

Search can be slow for large histories. There is no calibrated relevance threshold: up to five nearest entries may include weak matches, and similarity does not establish answerability. Broad questions need a future coverage policy. Per-entry reads and metadata pages are not an atomic whole-history snapshot. A source edit/deletion after its read can still occur. Cancellation is checked between reads/inference calls; an active native call is not interruptible. This version does not promise constant memory for large bodies or immediate cancellation during model loading.

Verification uses synthetic stores and injected embeddings for pagination beyond 50 entries, current edits, live deletion exclusion, date filtering, excerpt selection/citations, Unicode chunking, invalid vectors and cancellation. An opt-in native test verifies an English question retrieves an older Chinese interview entry over an unrelated recent baking entry:

```sh
JOURNAL_EMBEDDING_MODEL="$PWD/Models/Qwen3-Embedding-0.6B-Q8_0.gguf" swift test --filter SemanticRetrievalTests/testNativeSyntheticSemanticRetrieval
```

No real Journal content is needed for these checks. Tests establish the retrieval path, not general search quality on a personal history.
