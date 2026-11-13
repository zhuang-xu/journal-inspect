import Foundation

public struct JournalContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let text: String
    public let citationIDs: [String]
    public let omittedCount: Int
    public let references: [JournalEvidenceReference]

    public init(
        text: String, citationIDs: [String], omittedCount: Int,
        references: [JournalEvidenceReference] = []
    ) {
        self.text = text
        self.citationIDs = citationIDs
        self.omittedCount = omittedCount
        self.references = references
    }

    public var description: String { "JournalContext(redacted)" }
    public var debugDescription: String { description }
}

/// UTF-8 byte count is a conservative proxy for byte-based model tokenizers.
/// The budget covers context JSON only; callers reserve space for instructions/prompt/answer.
public struct BudgetedContextBuilder: Sendable {
    private struct Record: Encodable {
        let citation: String
        let date: Date?
        let text: String
    }

    public init() {}

    public func build(from evidence: [JournalEvidence], tokenBudget: Int) throws -> JournalContext {
        guard AugmentationLimits.contextBudget.contains(tokenBudget) else {
            throw AugmentationError.invalidBudget
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var records = [Record]()
        var citationIDs = [String]()
        var references = [JournalEvidenceReference]()
        var seen = Set<String>()
        var text = "[]"
        var omittedCount = 0

        for entry in evidence {
            try Task.checkCancellation()
            guard seen.insert(entry.id).inserted else { continue }

            let candidate =
                records + [Record(citation: entry.id, date: entry.date, text: entry.text)]
            let data = try encoder.encode(candidate)
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                data.count <= tokenBudget
            else {
                omittedCount += 1
                continue
            }

            records = candidate
            citationIDs.append(entry.id)
            if let reference = entry.reference { references.append(reference) }
            text = String(decoding: data, as: UTF8.self)
        }

        return JournalContext(
            text: text, citationIDs: citationIDs, omittedCount: omittedCount,
            references: references)
    }
}
