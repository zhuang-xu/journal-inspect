import Foundation

/// Implementations own model loading. No model runtime dependency enters JournalCore.
public protocol JournalTextEmbedding: Sendable {
    func embedDocument(_ text: String) async throws -> [Float]
    func embedQuery(_ text: String) async throws -> [Float]
}

public enum SemanticRetrievalError: Error {
    case emptyQuery
    case invalidVector
}

/// Exhaustive, transient semantic search over the synced corpus, not just recent entries.
/// Ranks by the best passage per entry and expands the retained excerpts in memory.
public struct SemanticJournalRetriever: JournalRetrieving {
    private let source: OnDemandJournalSource
    private let embeddings: any JournalTextEmbedding

    public init(
        embeddings: any JournalTextEmbedding,
        source: OnDemandJournalSource = OnDemandJournalSource()
    ) {
        self.embeddings = embeddings
        self.source = source
    }

    public func retrieve(_ request: RetrievalRequest) async throws -> [JournalEvidence] {
        try Task.checkCancellation()
        guard AugmentationLimits.retrievalCount.contains(request.limit) else {
            throw AugmentationError.invalidLimit
        }
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SemanticRetrievalError.emptyQuery
        }
        let query = try EmbeddingVector.normalized(try await embeddings.embedQuery(request.query))
        var best = [(score: Double, evidence: JournalEvidence)]()
        var offset = 0

        while true {
            try Task.checkCancellation()
            let page = try await source.page(for: request, offset: offset, pageSize: 50)
            for entry in page.evidence {
                var selected: (score: Double, passage: JournalPassages.Located)?
                for passage in JournalPassages.located(entry.text) {
                    try Task.checkCancellation()
                    let vector = try EmbeddingVector.normalized(
                        try await embeddings.embedDocument(passage.text))
                    guard vector.count == query.count else {
                        throw SemanticRetrievalError.invalidVector
                    }
                    let score = zip(query, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
                    if score > (selected?.score ?? -.infinity) {
                        selected = (score, passage)
                    }
                }
                guard let selected else { continue }
                let insertion =
                    best.firstIndex {
                        selected.score > $0.score
                            || (selected.score == $0.score && entry.id < $0.evidence.id)
                    } ?? best.endIndex
                guard insertion < request.limit else { continue }
                let passage = selected.passage
                let reference = JournalEvidenceReference(
                    sourceID: entry.sourceID, uuid: entry.uuid,
                    revision: JournalEvidenceReference.transientRevision(entry.text),
                    date: entry.date, offset: passage.offset, length: passage.length)
                let evidence = reference.expandedEvidence(passage, in: entry.text, date: entry.date)
                best.insert((selected.score, evidence), at: insertion)
                if best.count > request.limit { best.removeLast() }
            }
            guard let next = page.nextOffset else { break }
            offset = next
        }
        try Task.checkCancellation()
        return best.map(\.evidence)
    }
}
