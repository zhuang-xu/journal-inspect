# Journal application instructions

## Authoritative workspace

- This directory is the authoritative Swift application workspace for Journal Inspect.
- Inspect current source, call sites, `Package.swift`, `project.yml`, and relevant architecture documentation before changing architecture or proposing integrations.
- The Python ingestion adapter in the separate Journal workspace is a separate project. Setup scripts here are tooling, not the application runtime.

## Standing architecture and code requirement

The user expects architecture and code cleanliness on every change. This is a completion requirement, not an optional follow-up. Do not wait for another cleanup request to address problems introduced or exposed by the work.

- Give each component one clear responsibility and an identifiable owner. Keep view rendering, presentation state, application workflows, domain rules, persistence, and native model resources at their appropriate boundaries.
- Assemble shared dependencies explicitly at the application composition root. Avoid hidden construction of sibling features, duplicate stores, and unnecessary global state.
- Keep `JournalCore` independent of SwiftUI and llama.cpp. Native model loading, inference, and resource lifetime belong to the model modules; UI progress and request identity belong to presentation models.
- Prefer the smallest coherent design that supports current behavior. Do not introduce speculative protocols, factories, wrappers, parallel implementations, or future-only abstractions without a concrete caller and purpose.
- Use one implementation for each supported behavior unless distinct strategies are intentional and actually selected by the application. A fallback must have a real invocation path and defined failure behavior; an unused implementation is not a fallback.
- Remove obsolete code, unused production types, abandoned strategies, stale comments, and redundant helpers within the affected scope. Search actual call sites before deciding a component is needed. A test that exercises only an otherwise unused implementation does not justify keeping it in production.
- Before removing a public symbol, check application, test, and documented consumer usage. Preserve supported contracts or update their consumers together. Do not delete behavior merely to make a check pass.
- Consolidate repeated policy such as cancellation, model cleanup, filesystem permissions, and vector validation where the behavior is genuinely shared. Keep store-specific schemas and transaction decisions with their owners.
- Preserve cancellation propagation, actor isolation, request guards, and resource cleanup on success and failure. Blocking SQLite work must not run on the main actor, and database handles must remain local to their worker or owning actor.
- Preserve Journal privacy and read-only source access. Do not log journal text, memories, prompts, answers, raw model output, or vectors during cleanup or validation.

## Required review before completion

For every implementation change, review the affected feature end to end, including callers, dependencies, tests, build configuration, and current documentation. For a whole-project architecture review, audit every first-party module and application workflow; inspecting only formatting and test results is insufficient.

1. Search references for affected types and helpers. Identify unused implementations, misleading fallbacks, duplicate responsibilities, obsolete paths, and stale names. Resolve findings in scope instead of merely noting them in a report.
2. Remove or update associated tests, imports, source references, and current docs when code is deleted or moved. Retain tests for supported behavior. Historical archives may describe removed implementations as history.
3. Update `project.yml` when target configuration changes and regenerate `JournalInspect.xcodeproj` with `xcodegen generate` after source additions, moves, or removals. Check that removed files have no remaining build references.
4. Run meaningful checks for the change. Use the Swift package tests for Core/model changes, a macOS app build for application wiring or target changes, and the repository's Swift formatter for affected Swift files. Whole-project cleanup requires recursive formatting validation. Avoid tests that merely mirror implementation structure.
5. Review the final diff for accidental behavior changes, unnecessary abstractions, unrelated edits, and documentation claims that no longer match code.
6. Report what changed, what was verified, and material limits. Distinguish passing, skipped, and blocked checks. Passing tests or formatting alone does not establish that the architecture is clean. Do not claim live UI, native inference, or signing validation unless performed successfully.

Do not leave a discovered unused production component in place and then describe the affected architecture as fully cleaned. If a finding cannot be safely resolved within the authorized scope, state the concrete reason and the remaining issue explicitly.
