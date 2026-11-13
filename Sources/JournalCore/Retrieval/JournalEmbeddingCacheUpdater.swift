import Foundation

public enum JournalCacheProgress: Sendable {
    case checkingSource
    case updating(completed: Int, total: Int)
    case searching
    case validating
}

/// Required refreshes are foreground work; this does not trigger optional memory extraction.
public struct JournalEmbeddingCacheUpdater: Sendable {
    let cache: JournalEmbeddingCache
    let embeddings: any IdentifiedJournalTextEmbedding
    let source: OnDemandJournalSource
    let progress: (@Sendable (JournalCacheProgress) -> Void)?

    public init(
        cache: JournalEmbeddingCache, embeddings: any IdentifiedJournalTextEmbedding,
        source: OnDemandJournalSource = OnDemandJournalSource(),
        progress: (@Sendable (JournalCacheProgress) -> Void)? = nil
    ) {
        self.cache = cache
        self.embeddings = embeddings
        self.source = source
        self.progress = progress
    }

    public func update() async throws -> JournalMetadataManifest {
        let space = try await embeddings.embeddingSpace()
        let ticket = try await cache.begin(space: space)
        do {
            let manifest = try await update(space: space, ticket: ticket)
            await cache.end(ticket)
            return manifest
        } catch {
            await cache.end(ticket)
            throw error
        }
    }

    func update(space: EmbeddingSpace, ticket: UUID) async throws -> JournalMetadataManifest {
        progress?(.checkingSource)
        let source = self.source
        let manifest = try await journalWorker {
            let sync = try JournalReader(sourceURL: source.sourceURL).synchronize(
                to: source.indexDirectory)
            return try JournalMetadataStore(directory: source.indexDirectory).manifest(
                for: sync.receipt)
        }
        try await cache.reconcile(manifest, space: space, ticket: ticket)
        var reused = 0
        var rebuilt = 0
        for (i, entry) in manifest.entries.enumerated() {
            try Task.checkCancellation()
            progress?(.updating(completed: i, total: manifest.entries.count))
            let header = try await cache.header(space: space, entry: entry)
            if let header, header.fingerprint == entry.fingerprint {
                reused += 1
                continue
            }
            let loaded: LoadedJournalEntry
            do {
                loaded = try await journalWorker {
                    try JournalReader(sourceURL: source.sourceURL).openEntry(
                        uuid: entry.uuid, sourceID: entry.sourceID)
                }
            } catch let error as JournalReaderError where error.code == "entry_unavailable" {
                throw JournalCacheError.sourceChanged
            }
            let revision = try await cache.revision(loaded.text)
            let version: Int64
            let passages = JournalPassages.located(loaded.text)
            let canReuse: Bool
            if let header, header.revision == revision {
                canReuse = try await cache.matchesLayout(
                    version: header.version, passages: passages)
            } else {
                canReuse = false
            }
            if let header, canReuse {
                version = header.version
                reused += 1
            } else {
                version = try await cache.draft(
                    entry: entry, space: space, revision: revision,
                    date: loaded.date, count: passages.count, ticket: ticket)
                for (ordinal, passage) in passages.enumerated() {
                    try Task.checkCancellation()
                    let vector = try await embeddings.embedDocument(passage.text)
                    try await cache.append(
                        version: version, ordinal: ordinal, passage: passage,
                        vector: vector, space: space, ticket: ticket)
                }
                rebuilt += 1
            }
            // Reopen after inference; a fingerprint from preflight alone cannot prove validity.
            let current = try await journalWorker {
                try JournalReader(sourceURL: source.sourceURL).openEntry(
                    uuid: entry.uuid, sourceID: entry.sourceID)
            }
            guard try await cache.revision(current.text) == revision, current.date == loaded.date
            else {
                throw JournalCacheError.sourceChanged
            }
            let receipt = try await journalWorker {
                try JournalMetadataStore(directory: source.indexDirectory).currentReceipt()
            }
            guard receipt == manifest.receipt else { throw JournalCacheError.sourceChanged }
            try await cache.publish(
                version: version, entry: entry, space: space, date: current.date, ticket: ticket)
        }
        let receipt = try await journalWorker {
            try JournalMetadataStore(directory: source.indexDirectory).currentReceipt()
        }
        guard receipt == manifest.receipt else { throw JournalCacheError.sourceChanged }
        try await cache.finish(
            manifest: manifest, space: space, reused: reused, rebuilt: rebuilt, ticket: ticket)
        return manifest
    }
}
