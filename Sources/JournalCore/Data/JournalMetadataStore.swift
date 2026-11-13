import CryptoKit
import Foundation

/// Owns the local metadata index. Original Journal content is never persisted here.
public final class JournalMetadataStore {
    static let fileName = "journal-index.sqlite3"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/JournalInspect", isDirectory: true)
    }

    private let database: Database
    private let fingerprintKey: SymmetricKey

    public init(directory: URL) throws {
        let databaseURL = try PrivateStoreFile.prepare(in: directory, named: Self.fileName)
        let database = try Database(databaseURL.path, readOnly: false)
        try Self.validateDestination(database)

        try database.execute("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL")
        let key = try database.transaction {
            try database.execute(Schema.sql)
            try Statement(database, "INSERT OR IGNORE INTO settings VALUES('index_instance_id',?)")
                .execute([UUID().uuidString])
            try database.execute("INSERT OR IGNORE INTO settings VALUES('metadata_generation','0')")
            return try Self.loadOrCreateFingerprintKey(in: database)
        }

        self.database = database
        self.fingerprintKey = key
    }

    func importEntries(
        reader: JournalReader,
        source: Database,
        progress: (@Sendable (Int) -> Void)?
    ) throws -> SyncResult {
        let session = try MetadataImport(database: database)

        let result = try database.transaction {
            try session.begin()
            let sourceID = try reader.stream(source: source, key: fingerprintKey) { entry in
                try session.observe(entry)
                if session.entriesSeen % 250 == 0 { progress?(session.entriesSeen) }
            }
            let result = try session.complete(sourceID: sourceID)
            try Task.checkCancellation()
            return result
        }
        progress?(result.seen)
        return result
    }

    /// Metadata only, ordered by entry date (falling back to creation), then identity.
    /// Date bounds are inclusive start / exclusive end. Offset pages reflect current index state.
    public func browse(
        start: Date? = nil, end: Date? = nil, limit: Int = 50, offset: Int = 0,
        includeDeleted: Bool = false
    ) throws -> EntryPage {
        try require((1...500).contains(limit) && offset >= 0, "Invalid page size or offset.")
        if let start, let end { try require(start < end, "Start date must precede end date.") }
        var conditions = includeDeleted ? [String]() : ["is_deleted=0"]
        var values = [String?]()
        if let start {
            conditions.append("COALESCE(entry_date,created)>=CAST(? AS REAL)")
            values.append(String(start.timeIntervalSinceReferenceDate))
        }
        if let end {
            conditions.append("COALESCE(entry_date,created)<CAST(? AS REAL)")
            values.append(String(end.timeIntervalSinceReferenceDate))
        }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        // One read transaction keeps count and rows consistent with a concurrent sync.
        try database.execute("BEGIN")
        defer { try? database.execute("ROLLBACK") }
        let count = try Statement(database, "SELECT count(*) FROM entries" + filter)
        try count.bind(values)
        _ = try count.next()
        let total = Int(count.integer(0))
        let query = try Statement(
            database,
            """
            SELECT source_id,uuid,created,modified,entry_date,fingerprint,is_deleted FROM entries
            \(filter) ORDER BY COALESCE(entry_date,created) DESC,source_id,uuid LIMIT ? OFFSET ?
            """)
        try query.bind(values + [String(limit), String(offset)])
        var entries = [JournalEntry]()
        while try query.next() {
            entries.append(
                JournalEntry(
                    sourceID: query.text(0)!, uuid: query.text(1)!,
                    created: query.number(2), modified: query.number(3), entryDate: query.number(4),
                    fingerprint: query.text(5)!, deleted: query.integer(6) != 0))
        }
        return EntryPage(
            entries: entries, total: total,
            nextOffset: offset + entries.count < total ? offset + entries.count : nil)
    }

    /// One immutable, source-scoped snapshot. A stale receipt cannot authorize reconciliation.
    public func manifest(for receipt: JournalSyncReceipt) throws -> JournalMetadataManifest {
        try database.execute("BEGIN")
        defer { try? database.execute("ROLLBACK") }
        guard try currentReceipt() == receipt else { throw JournalCacheError.sourceChanged }
        let query = try Statement(
            database,
            "SELECT uuid,created,modified,entry_date,fingerprint FROM entries WHERE source_id=? AND is_deleted=0 ORDER BY uuid"
        )
        try query.bind([receipt.sourceID])
        var entries: [JournalEntry] = []
        while try query.next() {
            entries.append(
                JournalEntry(
                    sourceID: receipt.sourceID, uuid: query.text(0)!,
                    created: query.number(1), modified: query.number(2), entryDate: query.number(3),
                    fingerprint: query.text(4)!, deleted: false))
        }
        return JournalMetadataManifest(receipt: receipt, entries: entries)
    }

    public func currentReceipt() throws -> JournalSyncReceipt {
        let query = try Statement(
            database,
            "SELECT (SELECT value FROM settings WHERE key='current_source_id'), (SELECT value FROM settings WHERE key='index_instance_id'), (SELECT value FROM settings WHERE key='metadata_generation')"
        )
        _ = try query.next()
        guard let source = query.text(0), let instance = query.text(1) else {
            throw JournalCacheError.sourceChanged
        }
        return JournalSyncReceipt(
            sourceID: source, indexInstanceID: instance, generation: query.integer(2))
    }

    public func syncStatus() throws -> JournalSyncStatus {
        let success = try Statement(database, "SELECT MAX(last_successful_sync_at) FROM sources")
        _ = try success.next()
        let lastSuccess = success.number(0).map(Date.init(timeIntervalSince1970:))
        let run = try Statement(
            database,
            """
            SELECT finished_at,status,entries_seen,entries_changed,entries_removed,error_code
            FROM sync_runs ORDER BY finished_at DESC,run_id DESC LIMIT 1
            """)
        let hasRun = try run.next()
        return JournalSyncStatus(
            lastSuccessfulSync: lastSuccess,
            finishedAt: hasRun ? run.number(0).map(Date.init(timeIntervalSince1970:)) : nil,
            state: hasRun ? run.text(1) : nil,
            seen: hasRun ? Int(run.integer(2)) : 0,
            changed: hasRun ? Int(run.integer(3)) : 0,
            removed: hasRun ? Int(run.integer(4)) : 0,
            errorCode: hasRun ? run.text(5) : nil)
    }

    func recordSyncFailure(_ error: Error) {
        try? MetadataImport(database: database).recordFailure(error)
    }

    private static func validateDestination(_ database: Database) throws {
        let tableCount = try database.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table'")
        let applicationID = try database.scalar("PRAGMA application_id")
        let version = try database.scalar("PRAGMA user_version")
        let isNewDatabase = tableCount == "0" && applicationID == "0" && version == "0"

        try require(
            isNewDatabase || applicationID == Schema.applicationID,
            "Destination is not a Journal metadata index.")
        try require(
            version == "0" || version == Schema.version,
            "Unsupported metadata schema version.")
    }

    private static func loadOrCreateFingerprintKey(in database: Database) throws -> SymmetricKey {
        let candidate = SymmetricKey(size: .bits256).withUnsafeBytes {
            Data($0).base64EncodedString()
        }
        let insert = try Statement(database, "INSERT OR IGNORE INTO settings VALUES('hmac_key', ?)")
        try insert.execute([candidate])

        let encodedKey = try database.scalar("SELECT value FROM settings WHERE key='hmac_key'")
        guard let data = Data(base64Encoded: encodedKey), data.count == 32 else {
            throw JournalReaderError(message: "Invalid metadata fingerprint key.")
        }
        return SymmetricKey(data: data)
    }
}

private enum Schema {
    static let applicationID = "1246645298"
    static let version = "1"

    static let sql = """
        PRAGMA application_id=\(applicationID);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sources(
            source_id TEXT PRIMARY KEY, first_seen_at REAL NOT NULL, last_successful_sync_at REAL);
        CREATE TABLE IF NOT EXISTS entries(
            source_id TEXT NOT NULL REFERENCES sources(source_id), uuid TEXT NOT NULL,
            created REAL, modified REAL, entry_date REAL, fingerprint TEXT NOT NULL,
            fingerprint_version INTEGER NOT NULL DEFAULT 1,
            is_deleted INTEGER NOT NULL CHECK(is_deleted IN (0,1)),
            first_seen_at REAL NOT NULL, last_seen_at REAL NOT NULL, last_changed_at REAL NOT NULL,
            PRIMARY KEY(source_id, uuid));
        CREATE TABLE IF NOT EXISTS sync_runs(
            run_id TEXT PRIMARY KEY, source_id TEXT,
            started_at REAL NOT NULL, finished_at REAL NOT NULL,
            status TEXT NOT NULL, entries_seen INTEGER NOT NULL,
            entries_changed INTEGER NOT NULL, entries_removed INTEGER NOT NULL, error_code TEXT);
        CREATE TABLE IF NOT EXISTS scan_seen(uuid TEXT PRIMARY KEY) WITHOUT ROWID;
        PRAGMA user_version=\(version);
        """
}
