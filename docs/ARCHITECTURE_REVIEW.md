# Architecture and code cleanup

Reviewed and implemented on 2026-11-06 in the authoritative Swift workspace. Scope: application composition and views, Core data/memory/prompt/retrieval code, native generation/embedding ownership, package/Xcode configuration, tests, setup scripts and current architecture documentation. Third-party vendor implementations and model weights were not rewritten.

## Decisions and implemented changes

| Finding | Change |
| --- | --- |
| Prompt UI state also owned retrieval setup, freshness scans and repeated embedding load/unload paths | Added `App/JournalPromptService.swift`; the view model delegates preparation/cache work while retaining UI state, request guards and generation presentation |
| Reader feature constructed sibling feature models and their shared persistence dependency | Added `JournalAppComposition` in the app entrypoint; dependencies are explicitly injected into Reader, Memory and Prompt view models, once per window |
| Detached SQLite worker cancellation was implemented independently by retrieval and memory, while opening a memory source did not forward cancellation | Added `JournalWorker.swift`; callers share cancellation forwarding and checks before work/return, and memory source opening now uses it |
| Three stores independently created private directories/files and repaired permissions at different times | Added `PrivateStoreFile.swift`; private permissions are established before SQLite opens, existing permissions are repaired, and symlink/nonregular destinations are rejected |
| Cache serialization depended on a concrete transient retriever for vector validation | Moved normalization to `Retrieval/EmbeddingVector.swift` |
| Semantic ranking and passage splitting lived under Prompt; cache updater and retriever were one file | Grouped retrieval implementation under Retrieval and gave passage splitting and cache updates their own files |
| Context JSON deduplicated entry identities, but a later reference-building pass could retain discarded duplicates | References now follow exactly the selected evidence; added a regression using two revisions/locations for one identity |
| Transaction wrapper was surrounded by a catch that only rethrew | Removed the redundant catch; rollback ownership remains in `Database.transaction` |
| Two Swift files drifted from the repository formatter | Applied the existing `.swift-format` policy; recursive strict lint passes for App, Sources and Tests |

SQLite schema versions, fingerprint framing, embedding-space identity and passage splitting behavior retain their existing formats. No data migration is needed for these changes. The generated Xcode project includes the moved/new files; `project.yml` remains its source configuration.

## Verification

- `swift test --disable-sandbox` with workspace-local Clang/SwiftPM module caches: **101 tests discovered; 94 passed, seven opt-in tests skipped, zero failures** across Core, Embeddings and Generation.
- New tests cover duplicate evidence reference selection, cancellation before work begins, cancellation reaching a running worker, private file permission repair, and directory/file symlink rejection.
- `xcrun swift-format lint --strict --recursive App Sources Tests`: passed without diagnostics.
- Debug macOS `JournalInspectApp` build: passed with signing disabled and isolated build products. The compiler's `-disable-sandbox` flag was supplied only on the validation command because the outer execution sandbox prevents SwiftUI macro subprocess sandbox creation.
- Development-signed build was attempted but could not find an accessible matching Mac Development certificate/private key in this execution environment. Signing configuration was not changed.

Native inference and real-history checks remain opt-in and were not run for this cleanup. This verification does not measure retrieval quality, model accuracy or live UI behavior.

## Boundaries retained after review

- Core has no llama.cpp dependency; native resources remain owned by the embedding/generation actors. No new framework or dependency-injection container is needed for this project size.
- Reader remains the window coordinator for mutually exclusive sync, memory and prompt operations. A separate coordinator can become useful if independent windows or overlapping model jobs become product requirements.
- Memory persistence still rewrites one transactional Codable state document. This is reasonable for the current bounded personal app; a normalized memory schema would need its own migration and measured scale justification.
- Prompt/evidence JSON is still a serialization boundary shared with model formatting and previews. Changing it to a typed schema should be a separate compatibility change with explicit handling for persisted/versioned representations.
- Apple Journal's private schema, finite model context, source changes after preflight and incomplete historical synthesis remain documented product limitations, not guarantees supplied by this refactor.
