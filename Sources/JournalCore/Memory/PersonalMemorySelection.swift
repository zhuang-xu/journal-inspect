import Foundation

/// Relevance is a ranking signal, not factual verification or a calibrated probability.
/// The operating point is specific to the pinned Qwen embedding space; see memory evaluation docs.
enum PersonalMemorySelection {
    static let minimumSimilarity = 0.5

    static func profile(
        _ candidates: [(memory: PersonalMemory, score: Double)], omittedCount: Int
    ) throws -> PersonalMemoryProfile {
        struct Item: Encodable {
            let id: UUID
            let statement: String
            let asOf: Date?
            let origin: MemoryOrigin
            let review: String
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let a = lhs.memory
            let b = rhs.memory
            if a.origin != b.origin { return a.origin == .user }
            if a.state != b.state { return a.state == .active }
            if a.asOf != b.asOf { return (a.asOf ?? .distantPast) > (b.asOf ?? .distantPast) }
            return a.id.uuidString < b.id.uuidString
        }
        var seen: Set<String> = []
        var items: [Item] = []
        for candidate in ordered {
            try Task.checkCancellation()
            guard candidate.score.isFinite, candidate.score >= minimumSimilarity else { continue }
            let memory = candidate.memory
            guard seen.insert(memoryKey(memory.statement)).inserted else { continue }
            items.append(
                Item(
                    id: memory.id, statement: memory.statement, asOf: memory.asOf,
                    origin: memory.origin,
                    review: memory.origin == .user
                        ? "user_authored"
                        : memory.state == .active ? "confirmed" : "automatic_unconfirmed"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return PersonalMemoryProfile(
            text: String(decoding: try encoder.encode(items), as: UTF8.self),
            omittedCount: omittedCount + candidates.count - items.count)
    }
}
