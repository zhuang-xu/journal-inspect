import Foundation

/// Explicit retrieval intent. Dates are inclusive start / exclusive end.
public struct RetrievalRequest: Sendable {
    public let query: String
    public let start: Date?
    public let end: Date?
    public let limit: Int

    public init(query: String, start: Date? = nil, end: Date? = nil, limit: Int = 5) {
        self.query = query
        self.start = start
        self.end = end
        self.limit = limit
    }
}

/// Transient evidence; never pass to the metadata store or diagnostic logging.
public struct JournalEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sourceID: String
    public let uuid: String
    public let date: Date?
    public let text: String
    public let reference: JournalEvidenceReference?

    public var id: String { sourceID + ":" + uuid }
    public var description: String { "JournalEvidence(redacted)" }
    public var debugDescription: String { description }

    public init(
        sourceID: String, uuid: String, date: Date?, text: String,
        reference: JournalEvidenceReference? = nil
    ) {
        self.sourceID = sourceID
        self.uuid = uuid
        self.date = date
        self.text = text
        self.reference = reference
    }
}

public protocol JournalRetrieving: Sendable {
    func retrieve(_ request: RetrievalRequest) async throws -> [JournalEvidence]
}

/// Pass the question through; the injected retriever decides how to select evidence.
public enum JournalQueryPlanner {
    public static func request(for prompt: String) -> RetrievalRequest {
        RetrievalRequest(query: prompt, limit: 25)
    }
}
