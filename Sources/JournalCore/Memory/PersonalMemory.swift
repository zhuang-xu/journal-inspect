import CryptoKit
import Foundation

public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    case circumstance, goal, relationship, preference
}
public enum MemoryOrigin: String, Codable, Sendable { case automatic, user }
public enum MemoryState: String, Codable, Sendable {
    case active, unreviewed, outdated, awaitingClarification

    public var displayName: String {
        switch self {
        case .active: return "confirmed"
        case .unreviewed: return "automatic (unconfirmed)"
        case .outdated: return "outdated"
        case .awaitingClarification: return "needs clarification"
        }
    }
}

public struct MemorySource: Codable, Equatable, Sendable {
    public let sourceID: String
    public let uuid: String
    public let fingerprint: String
    public let textRevision: String
    public let date: Date?
    public let utf8Offset: Int
    public let utf8Length: Int
    public var entryID: String { sourceID + ":" + uuid }
}

public struct PersonalMemory: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let id: UUID
    public var statement: String
    public var category: MemoryCategory
    public var asOf: Date?
    public var sources: [MemorySource]
    public var origin: MemoryOrigin
    public var state: MemoryState
    public var processingVersion: String
    public var description: String { "PersonalMemory(redacted)" }
    public var debugDescription: String { description }
}

public struct MemorySnapshot: Sendable {
    public let enabled: Bool
    public let records: [PersonalMemory]
    public let processedEntryCount: Int
    public let lastBuild: MemoryBuildReport?
}

public struct PersonalMemoryProfile: Sendable {
    public let text: String
    public let omittedCount: Int
    public init(text: String = "[]", omittedCount: Int = 0) {
        self.text = text
        self.omittedCount = omittedCount
    }
}

/// Quotes are validated against the current source before any model output is stored.
public struct MemoryCandidate: Codable, Sendable {
    public let statement: String
    public let category: MemoryCategory
    public let quote: String
    public init(statement: String, category: MemoryCategory, quote: String) {
        self.statement = statement
        self.category = category
        self.quote = quote
    }
}

public protocol PersonalMemoryExtracting: Sendable {
    var processingVersion: String { get }
    func extract(from text: String) async throws -> [MemoryCandidate]
}

public enum PersonalMemoryError: Error { case invalidCandidate, disabled, staleUpdate }

func memoryRevision(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
func memoryKey(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}

public enum MemoryBuildStatus: String, Codable, Sendable {
    case running, completed, cancelled, failed
}

/// Aggregate diagnostics only: never retain entry bodies, model output or private statements.
public struct MemoryBuildReport: Codable, Sendable {
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: MemoryBuildStatus = .running
    public let totalEntries: Int
    public var completedEntries = 0
    public var extractedEntries = 0
    public var unchangedEntries = 0
    public var unavailableEntries = 0
    public var candidateCount = 0
    public var failedEntries: Int? = 0
    public var nonemptyEntries: Int? = 0
    public var decodedTextBytes: Int? = 0
    public var zeroCandidateEntries: Int? = 0

    public init(totalEntries: Int) {
        self.startedAt = Date()
        self.totalEntries = totalEntries
    }
}
