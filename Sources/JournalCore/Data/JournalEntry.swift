import Foundation

/// Metadata only. Source timestamps use Apple's 2001-01-01 UTC epoch.
public struct JournalEntry: Equatable, Identifiable, Sendable {
    public var id: String { sourceID + ":" + uuid }
    public let sourceID: String
    public let uuid: String
    public let created: Double?
    public let modified: Double?
    public let entryDate: Double?
    public let fingerprint: String
    public let deleted: Bool
}

public struct SyncResult: Sendable {
    public let seen: Int
    public let changed: Int
    public let removed: Int
    public let receipt: JournalSyncReceipt
}

public struct JournalSyncReceipt: Equatable, Sendable {
    public let sourceID: String
    public let indexInstanceID: String
    public let generation: Int64
}

public struct JournalMetadataManifest: Sendable {
    public let receipt: JournalSyncReceipt
    public let entries: [JournalEntry]
}

public struct EntryPage: Sendable {
    public let entries: [JournalEntry]
    public let total: Int
    public let nextOffset: Int?
}

public struct JournalSyncStatus: Sendable {
    public let lastSuccessfulSync: Date?
    public let finishedAt: Date?
    public let state: String?
    public let seen: Int
    public let changed: Int
    public let removed: Int
    public let errorCode: String?
}

/// Current text held only by the caller. Never persisted in the index.
public struct LoadedJournalEntry: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let uuid: String
    public let text: String
    public let date: Date?
    public var description: String { "LoadedJournalEntry(\(uuid), \(text.utf8.count) bytes)" }
    public var debugDescription: String { description }
}
