import Foundation

/// Prepared writes and counters for one atomic scan. Holds metadata only.
final class MetadataImport {
    private let database: Database
    private let markSeen: Statement
    private let insertSource: Statement
    private let findEntry: Statement
    private let upsertEntry: Statement
    private let runID = UUID().uuidString
    private let startedAt = Date().timeIntervalSince1970
    private var hasRegisteredSource = false
    private var entriesChanged = 0
    private(set) var entriesSeen = 0

    init(database: Database) throws {
        self.database = database
        markSeen = try Statement(database, "INSERT INTO scan_seen VALUES(?)")
        insertSource = try Statement(database, "INSERT OR IGNORE INTO sources VALUES(?, ?, NULL)")
        findEntry = try Statement(
            database,
            """
            SELECT fingerprint, is_deleted FROM entries WHERE source_id=? AND uuid=?
            """)
        upsertEntry = try Statement(
            database,
            """
            INSERT INTO entries(source_id, uuid, created, modified, entry_date, fingerprint,
                is_deleted, first_seen_at, last_seen_at, last_changed_at) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source_id, uuid) DO UPDATE SET
                created=excluded.created, modified=excluded.modified, entry_date=excluded.entry_date,
                fingerprint=excluded.fingerprint, is_deleted=excluded.is_deleted,
                last_seen_at=excluded.last_seen_at,
                last_changed_at=CASE WHEN entries.fingerprint != excluded.fingerprint
                    OR entries.is_deleted != excluded.is_deleted
                    THEN excluded.last_changed_at ELSE entries.last_changed_at END
            """)
    }

    func begin() throws {
        try database.execute("DELETE FROM scan_seen")
    }

    func observe(_ entry: JournalEntry) throws {
        if !hasRegisteredSource {
            try registerSource(entry.sourceID)
            hasRegisteredSource = true
        }
        // The disk-backed primary key detects duplicate UUIDs without an unbounded Set.
        try markSeen.execute([entry.uuid])
        if try hasChanged(entry) { entriesChanged += 1 }

        let observedAt = String(startedAt)
        try upsertEntry.execute([
            entry.sourceID, entry.uuid,
            entry.created.map { String($0) }, entry.modified.map { String($0) },
            entry.entryDate.map { String($0) }, entry.fingerprint,
            entry.deleted ? "1" : "0", observedAt, observedAt, observedAt,
        ])
        entriesSeen += 1
    }

    func complete(sourceID: String) throws -> SyncResult {
        // Register even a valid empty store before reconciling its missing entries.
        if !hasRegisteredSource { try registerSource(sourceID) }
        let removed = try markMissingEntriesDeleted(sourceID: sourceID)
        let updateSource = try Statement(
            database,
            """
            UPDATE sources SET last_successful_sync_at=? WHERE source_id=?
            """)
        try updateSource.execute([String(Date().timeIntervalSince1970), sourceID])
        try recordRun(sourceID: sourceID, removed: removed)
        try database.execute("DELETE FROM scan_seen")
        try database.execute(
            "UPDATE settings SET value=CAST(value AS INTEGER)+1 WHERE key='metadata_generation'")
        let generation = Int64(
            try database.scalar("SELECT value FROM settings WHERE key='metadata_generation'"))!
        let instance = try database.scalar(
            "SELECT value FROM settings WHERE key='index_instance_id'")
        try Statement(database, "INSERT OR REPLACE INTO settings VALUES('current_source_id',?)")
            .execute([sourceID])
        return SyncResult(
            seen: entriesSeen, changed: entriesChanged, removed: removed,
            receipt: JournalSyncReceipt(
                sourceID: sourceID, indexInstanceID: instance, generation: generation))
    }

    func recordFailure(_ error: Error) throws {
        let code =
            error is CancellationError
            ? "cancelled"
            : (error as? JournalReaderError)?.code ?? "scan_failed"
        try recordRun(sourceID: nil, removed: 0, errorCode: code)
    }

    private func registerSource(_ sourceID: String) throws {
        try insertSource.execute([sourceID, String(startedAt)])
    }

    private func hasChanged(_ entry: JournalEntry) throws -> Bool {
        try findEntry.bind([entry.sourceID, entry.uuid])
        guard try findEntry.next() else { return true }
        return findEntry.text(0) != entry.fingerprint
            || findEntry.integer(1) != (entry.deleted ? 1 : 0)
    }

    private func markMissingEntriesDeleted(sourceID: String) throws -> Int {
        let deletion = try Statement(
            database,
            """
            UPDATE entries SET is_deleted=1, last_changed_at=?
            WHERE source_id=? AND is_deleted=0
                AND NOT EXISTS(SELECT 1 FROM scan_seen WHERE scan_seen.uuid=entries.uuid)
            """)
        try deletion.execute([String(startedAt), sourceID])
        return database.changedRowCount
    }

    private func recordRun(sourceID: String?, removed: Int, errorCode: String? = nil) throws {
        let run = try Statement(
            database,
            """
            INSERT INTO sync_runs(run_id, source_id, started_at, finished_at, status,
                entries_seen, entries_changed, entries_removed, error_code) VALUES(?,?,?,?,?,?,?,?,?)
            """)
        let succeeded = errorCode == nil
        try run.execute([
            runID, sourceID, String(startedAt), String(Date().timeIntervalSince1970),
            succeeded ? "succeeded" : "failed", String(entriesSeen),
            String(succeeded ? entriesChanged : 0), String(removed), errorCode,
        ])
    }
}
