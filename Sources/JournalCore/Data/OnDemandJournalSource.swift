import Foundation

/// Worker-local SQLite handles; no database object crosses concurrency boundaries.
public struct OnDemandJournalSource: Sendable {
    public let sourceURL: URL
    public let indexDirectory: URL

    public init(
        sourceURL: URL = JournalReader().sourceURL,
        indexDirectory: URL = JournalMetadataStore.defaultDirectory
    ) {
        self.sourceURL = sourceURL
        self.indexDirectory = indexDirectory
    }

    /// Pages the candidate corpus independently of the final retrieval limit.
    func page(for request: RetrievalRequest, offset: Int, pageSize: Int) async throws
        -> (evidence: [JournalEvidence], nextOffset: Int?)
    {
        try await journalWorker {
            try loadEvidence(for: request, offset: offset, pageSize: pageSize)
        }
    }

    /// Synchronous so all SQLite work stays on the detached task's worker thread.
    private func loadEvidence(for request: RetrievalRequest, offset: Int, pageSize: Int) throws
        -> (evidence: [JournalEvidence], nextOffset: Int?)
    {
        try Task.checkCancellation()
        let store = try JournalMetadataStore(directory: indexDirectory)
        let page = try store.browse(
            start: request.start, end: request.end, limit: pageSize, offset: offset)
        let reader = JournalReader(sourceURL: sourceURL)

        var evidence = [JournalEvidence]()
        for entry in page.entries {
            try Task.checkCancellation()

            do {
                let loaded = try reader.openEntry(uuid: entry.uuid, sourceID: entry.sourceID)
                let date = loaded.date
                evidence.append(
                    JournalEvidence(
                        sourceID: entry.sourceID, uuid: entry.uuid, date: date, text: loaded.text))
            } catch let error as JournalReaderError where error.code == "entry_unavailable" {
                // Stale metadata must never resurrect a removed entry or another source's text.
                continue
            }
        }

        try Task.checkCancellation()
        return (evidence, page.nextOffset)
    }
}
