import Foundation

/// Exhaustive cosine ranking, bounded candidate memory and current-original evidence.
public struct CachedJournalRetriever: JournalRetrieving {
    private let updater: JournalEmbeddingCacheUpdater
    public init(
        cache: JournalEmbeddingCache, embeddings: any IdentifiedJournalTextEmbedding,
        source: OnDemandJournalSource = OnDemandJournalSource(),
        progress: (@Sendable (JournalCacheProgress) -> Void)? = nil
    ) {
        updater = JournalEmbeddingCacheUpdater(
            cache: cache, embeddings: embeddings, source: source, progress: progress)
    }
    public func retrieve(_ request: RetrievalRequest) async throws -> [JournalEvidence] {
        try Task.checkCancellation()
        guard AugmentationLimits.retrievalCount.contains(request.limit) else {
            throw AugmentationError.invalidLimit
        }
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SemanticRetrievalError.emptyQuery
        }
        if let start = request.start, let end = request.end, start >= end {
            throw AugmentationError.invalidLimit
        }
        let space = try await updater.embeddings.embeddingSpace()
        let query = try EmbeddingVector.normalized(
            try await updater.embeddings.embedQuery(request.query))
        guard query.count == space.dimensions else { throw SemanticRetrievalError.invalidVector }
        let ticket = try await updater.cache.begin(space: space)
        do {
            let evidence = try await retrieve(request, space: space, query: query, ticket: ticket)
            await updater.cache.end(ticket)
            return evidence
        } catch {
            await updater.cache.end(ticket)
            throw error
        }
    }
    private func retrieve(
        _ request: RetrievalRequest, space: EmbeddingSpace, query: [Double], ticket: UUID
    ) async throws -> [JournalEvidence] {
        for attempt in 0..<2 {
            do {
                let manifest = try await updater.update(space: space, ticket: ticket)
                updater.progress?(.searching)
                let candidates = try await updater.cache.rank(
                    query: query, space: space, sourceID: manifest.receipt.sourceID,
                    request: request, ticket: ticket)
                updater.progress?(.validating)
                var evidence: [JournalEvidence] = []
                var stale = false
                for candidate in candidates {
                    try Task.checkCancellation()
                    let ref = candidate.reference
                    let current: LoadedJournalEntry
                    do {
                        current = try await journalWorker {
                            try JournalReader(sourceURL: updater.source.sourceURL).openEntry(
                                uuid: ref.uuid, sourceID: ref.sourceID)
                        }
                    } catch let error as JournalReaderError where error.code == "entry_unavailable"
                    {
                        try await updater.cache.invalidate(
                            sourceID: ref.sourceID, uuid: ref.uuid, space: space)
                        stale = true
                        continue
                    }
                    guard
                        let text = try await ref.excerpt(
                            in: current,
                            currentRevision: .cached(updater.cache.revision(current.text)))
                    else {
                        try await updater.cache.invalidate(
                            sourceID: ref.sourceID, uuid: ref.uuid, space: space)
                        stale = true
                        continue
                    }
                    evidence.append(
                        ref.expandedEvidence(
                            .init(text: text, offset: ref.offset), in: current.text,
                            date: current.date))
                }
                if stale { throw JournalCacheError.sourceChanged }
                try await updater.cache.checkTicket(ticket)
                return evidence
            } catch JournalCacheError.sourceChanged where attempt == 0 { continue }
        }
        throw JournalCacheError.sourceChanged
    }
}
