import Foundation
import JournalCore
import JournalEmbeddings

/// Application workflow for local retrieval. UI state and request identity belong to the view model.
/// Each operation owns its embedding model and releases it before returning or throwing.
struct JournalPromptService: Sendable {
    let memoryStore: PersonalMemoryStore
    let cache: JournalEmbeddingCache
    let source: OnDemandJournalSource

    init(
        memoryStore: PersonalMemoryStore,
        cache: JournalEmbeddingCache,
        source: OnDemandJournalSource = OnDemandJournalSource()
    ) {
        self.memoryStore = memoryStore
        self.cache = cache
        self.source = source
    }

    func prepare(
        _ question: String, cacheEnabled: Bool,
        progress: @escaping @Sendable (JournalCacheProgress) -> Void
    ) async throws -> AugmentedPrompt {
        try await withEmbeddings { embeddings in
            let retriever: any JournalRetrieving
            if cacheEnabled {
                retriever = CachedJournalRetriever(
                    cache: cache, embeddings: embeddings, source: source, progress: progress)
            } else {
                _ = try await journalWorker {
                    try JournalReader(sourceURL: source.sourceURL).synchronize(
                        to: source.indexDirectory)
                }
                retriever = SemanticJournalRetriever(embeddings: embeddings, source: source)
            }
            let prompt = try await JournalPromptAugmenter(retriever: retriever).augment(question)
            let memory = try await memoryStore.profile(
                for: question, embeddings: embeddings, reuseCachedVectors: cacheEnabled,
                sourceURL: source.sourceURL)
            return AugmentedPrompt(
                instructions: prompt.instructions, userPrompt: prompt.userPrompt,
                context: prompt.context, memory: memory)
        }
    }

    func validateEvidence(in context: JournalContext) async throws -> Bool {
        guard context.references.count == context.citationIDs.count else { return false }
        return try await cache.validate(context.references, sourceURL: source.sourceURL)
    }

    /// Refresh background with the same selection policy before loading generation weights.
    func refreshMemory(
        for question: String, cacheEnabled: Bool
    ) async throws -> PersonalMemoryProfile {
        let snapshot = try await memoryStore.snapshot()
        guard snapshot.enabled,
            snapshot.records.contains(where: { $0.state == .active || $0.state == .unreviewed })
        else { return PersonalMemoryProfile() }
        return try await withEmbeddings { embeddings in
            try await memoryStore.profile(
                for: question, embeddings: embeddings, reuseCachedVectors: cacheEnabled,
                sourceURL: source.sourceURL)
        }
    }

    func updateCache(
        rebuild: Bool, progress: @escaping @Sendable (JournalCacheProgress) -> Void
    ) async throws {
        if rebuild { try await cache.clear() }
        _ = try await withEmbeddings { embeddings in
            try await JournalEmbeddingCacheUpdater(
                cache: cache, embeddings: embeddings, source: source,
                progress: progress
            ).update()
        }
    }

    private func withEmbeddings<T: Sendable>(
        operation: (LocalEmbeddingModel) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard let url = LocalEmbeddingModel.defaultModelURL else {
            throw EmbeddingError.modelUnavailable
        }
        let model = LocalEmbeddingModel()
        do {
            try await model.load(from: url)
            try Task.checkCancellation()
            let result = try await operation(model)
            await model.unload()
            try Task.checkCancellation()
            return result
        } catch {
            await model.unload()
            throw error
        }
    }
}
