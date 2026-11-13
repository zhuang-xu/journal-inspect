# Journal Inspect documentation

Current implementation reference, checked against the Swift source on 2026-11-06. Run commands from the project root, one level above `docs`.

| Read | Purpose |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Modules, source access, storage and the complete question-to-answer flow |
| [Prompt and output design](PROMPT_AND_OUTPUT_DESIGN.md) | Draft preparation, final model input, budgets, streaming and displayed answers |
| [Architecture review](ARCHITECTURE_REVIEW.md) | Cleanup decisions, verification and remaining boundaries |
| [Personal memory](PERSONAL_MEMORY.md) | Building and using background memory, optional confirmation, corrections and reset |
| [Embeddings and retrieval](EMBEDDINGS.md) | Model setup, semantic ranking, budgets and persistent vector reuse |
| [Local generation](GENERATION.md) | Supported weights, setup, chat formats, streaming and output limits |
| [Current status](STATUS.md) | Implemented features, known gaps and recorded validation |
| [Evidence pipeline evaluation](EVIDENCE_PIPELINE_EVALUATION.md) | Native bilingual development probes for source recall, passage retention and answer support |
| [Memory relevance evaluation](MEMORY_RELEVANCE_EVALUATION.md) | Question-aware selection, cache checks, development operating point and known misses |
| [Model evaluation](MODEL_UPGRADE_EVALUATION.md) | Dated 0.6B/4B comparison on synthetic fixtures and observed limitations |

## Run

Follow the [build and model setup instructions](../README.md).

Open `JournalInspect.xcodeproj`, select `JournalInspectApp`, and run. **Reflect** opens first. Pick an idea or write your own question, then choose **Ask Journal**. The app finds relevant excerpts and streams an answer locally. Use **Sources** to see the dated passages used for the answer. To review excerpts before asking, choose **Find excerpts before answering** from the question options.

**Entries** lets you browse original journal text, filter by date or deletion status, and refresh from Apple Journal. Asking a new question also checks for new or changed entries automatically. The app searches journal history by meaning, considers 25 candidates and fits whole excerpts to the prompt budget.

The gear opens **Journal Settings**. **Journal Access** contains sync details and index-folder access. **Answer Setup** contains local model selection and retrieval cache controls. **Personalization** contains opt-in saved background and its review and deletion controls. Enabled source-supported automatic memories can contribute to an answer without individual confirmation.

Full Disk Access may be needed for the app. The app does not change permissions or bypass macOS privacy controls.

## Current versus planned

Persistent data consists of model weights, a metadata-only Journal index, a separate private personal-memory store, and a private SQLite document/memory-vector cache. Journal passages, questions, answers and query vectors remain transient. Retrieval cache controls in **Journal Settings → Answer Setup** independently disable, update, rebuild or clear vector reuse. See [cache operation](EMBEDDING_CACHE.md).

- [Remaining roadmap](plans/ROADMAP.md)
- [Prompt and context improvement plan](plans/PROMPT_CONTEXT_IMPROVEMENT_PLAN.md)
- [SQLite embedding cache implementation design](plans/SQLITE_EMBEDDING_CACHE_DESIGN.md)

Older alternatives, milestone instructions and the detailed development log are preserved in the [historical archive](archive/README.md). They are not authoritative descriptions of the current app.

Licenses and weight provenance remain in [ThirdPartyNotices](ThirdPartyNotices/GenerationModels.md), including the [Apache 2.0 notice](ThirdPartyNotices/Apache-2.0.txt) and [llama.cpp license](ThirdPartyNotices/llama.cpp-LICENSE).
