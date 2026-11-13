import AppKit
import CryptoKit
import Foundation
import SQLite3

/// Indexes metadata and loads current entry text on demand without exporting bodies.
public final class JournalReader: Sendable {
    public let sourceURL: URL
    public let maximumReadDuration: TimeInterval

    public init(
        sourceURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.moments/Library/moments.sqlite"),
        maximumReadDuration: TimeInterval = 60
    ) {
        self.sourceURL = sourceURL
        self.maximumReadDuration = maximumReadDuration
    }

    public func synchronize(
        to directory: URL = JournalMetadataStore.defaultDirectory,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> SyncResult {
        let output = directory.appendingPathComponent(JournalMetadataStore.fileName)
        try require(
            output.resolvingSymlinksInPath() != sourceURL.resolvingSymlinksInPath(),
            "Source and metadata destination must differ.")
        let store = try JournalMetadataStore(directory: directory)
        do {
            return try withReadSource { source in
                try store.importEntries(reader: self, source: source, progress: progress)
            }
        } catch {
            store.recordSyncFailure(error)
            throw error
        }
    }

    /// Fetch the current body by UUID. Does not rely on stale indexed deletion state.
    /// Rich text is decoded in memory with the native RTF parser.
    public func openEntry(uuid: String, sourceID: String? = nil) throws -> LoadedJournalEntry {
        guard let identity = UUID(uuidString: uuid) else {
            throw JournalReaderError(message: "Invalid entry UUID.", code: "invalid_uuid")
        }
        return try withReadSource(prepareAssets: false) { database in
            let currentSource = try readSourceID(from: database)
            if let sourceID, currentSource != sourceID.lowercased() {
                throw JournalReaderError(
                    message: "This entry belongs to a different Journal store.",
                    code: "entry_unavailable")
            }
            let entry = try Statement(
                database,
                """
                SELECT ZTEXT,ZRECENTLYDELETED,ZISFULLYREMOVED,COALESCE(ZENTRYDATE,ZCREATEDDATE) FROM ZJOURNALENTRYMO
                WHERE (typeof(ZID)='blob' AND hex(ZID)=?) OR (typeof(ZID)='text' AND lower(ZID)=?)
                """)
            try entry.bind([
                identity.uuidString.replacingOccurrences(of: "-", with: ""),
                identity.uuidString.lowercased(),
            ])
            guard try entry.next() else {
                throw JournalReaderError(
                    message: "Entry no longer exists in Apple Journal. Sync to refresh the index.",
                    code: "entry_unavailable")
            }
            guard entry.integer(1) == 0 && entry.integer(2) == 0 else {
                throw JournalReaderError(
                    message: "Entry is deleted in Apple Journal. Sync to refresh the index.",
                    code: "entry_unavailable")
            }
            let date = entry.number(3).map(Date.init(timeIntervalSinceReferenceDate:))
            let data = entry.data(0) ?? Data()
            try require(try !entry.next(), "Duplicate Journal entry UUID.")
            try Task.checkCancellation()
            let text: String
            if data.starts(with: Data("{\\rtf".utf8)) {
                guard let rich = NSAttributedString(rtf: data, documentAttributes: nil) else {
                    throw JournalReaderError(
                        message: "Cannot decode Journal rich text.", code: "text_decode_failed")
                }
                text = rich.string
            } else {
                guard let plain = String(data: data, encoding: .utf8) else {
                    throw JournalReaderError(
                        message: "Unsupported Journal text encoding.", code: "text_decode_failed")
                }
                text = plain
            }
            try Task.checkCancellation()
            return LoadedJournalEntry(
                uuid: identity.uuidString.lowercased(), text: text, date: date)
        }
    }

    /// One consistent read transaction, without copying private content to disk.
    private func withReadSource<T>(prepareAssets: Bool = true, _ body: (Database) throws -> T)
        throws
        -> T
    {
        try Task.checkCancellation()
        let source = try Database(sourceURL.path, readOnly: true)
        let budget = ReadBudget(seconds: maximumReadDuration)
        sqlite3_progress_handler(
            source.handle, 1000,
            { context in
                guard let context else { return 0 }
                let budget = Unmanaged<ReadBudget>.fromOpaque(context).takeUnretainedValue()
                return budget.shouldInterrupt ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
        source.checkInterruption = { try budget.check() }
        defer {
            sqlite3_progress_handler(source.handle, 0, nil, nil)
            try? source.execute("ROLLBACK")
        }

        do {
            try source.execute("BEGIN")
            try validateSchema(source)
            // TEMP sorting contains numeric keys only. Body/title columns never spill.
            if prepareAssets {
                try source.execute(
                    """
                    CREATE TEMP TABLE asset_order(entry INTEGER, row_id INTEGER PRIMARY KEY);
                    INSERT INTO asset_order SELECT ZENTRY, Z_PK FROM ZJOURNALENTRYASSETMO;
                    CREATE INDEX temp.asset_order_index ON asset_order(entry, row_id);
                    """)
            }
            try source.execute("PRAGMA query_only=ON")
            return try body(source)
        } catch {
            try budget.check()
            throw error
        }
    }

    private func validateSchema(_ source: Database) throws {
        let tableCount = try source.scalar(
            """
            SELECT count(*) FROM sqlite_master
            WHERE type='table'
                AND name IN ('Z_METADATA', 'ZJOURNALENTRYMO', 'ZJOURNALENTRYASSETMO')
            """)
        try require(tableCount == "3", "Unsupported Journal tables.")

        for table in ["ZJOURNALENTRYMO", "ZJOURNALENTRYASSETMO"] {
            let primaryKeyCount = try source.scalar(
                """
                SELECT count(*) FROM pragma_table_info('\(table)')
                WHERE name='Z_PK' AND type='INTEGER' AND pk=1
                """)
            try require(primaryKeyCount == "1", "Unsupported Journal row identity.")
        }

        // Compile zero-row queries to validate required columns without reading content.
        try source.execute("SELECT Z_UUID FROM Z_METADATA LIMIT 0")
        try source.execute(
            """
            SELECT Z_PK, ZID, ZTEXT, ZCREATEDDATE, ZUPDATEDDATE, ZENTRYDATE,
                ZRECENTLYDELETED, ZISFULLYREMOVED
            FROM ZJOURNALENTRYMO LIMIT 0
            """)
        try source.execute(
            """
            SELECT Z_PK, ZENTRY, ZID, Z_OPT
            FROM ZJOURNALENTRYASSETMO LIMIT 0
            """)
    }

    func stream(
        source: Database,
        key: SymmetricKey,
        consume: (JournalEntry) throws -> Void
    ) throws -> String {
        let sourceID = try readSourceID(from: source)
        let entries = try JournalEntryCursor(database: source)
        var assets = try JournalAssetCursor(database: source)

        while try entries.advance() {
            try Task.checkCancellation()

            var fingerprint = EntryFingerprint(key: key)
            fingerprint.append(entries.statement)
            try assets.appendAssets(for: entries.rowID, to: &fingerprint)

            let entry = try entries.metadata(
                sourceID: sourceID,
                fingerprint: fingerprint.finish()
            )
            try consume(entry)
        }

        return sourceID
    }

    private func readSourceID(from database: Database) throws -> String {
        let stores = try Statement(database, "SELECT Z_UUID FROM Z_METADATA")
        try require(try stores.next(), "Missing Journal store identity.")

        guard let value = stores.text(0), let uuid = UUID(uuidString: value) else {
            throw JournalReaderError(message: "Invalid Journal store identity.")
        }

        try require(try !stores.next(), "Ambiguous Journal store identity.")
        return uuid.uuidString.lowercased()
    }
}

private final class ReadBudget {
    private let deadline: TimeInterval

    init(seconds: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
    }

    var shouldInterrupt: Bool {
        Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
    }

    func check() throws {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.systemUptime >= deadline {
            throw JournalReaderError(
                message: "Journal read exceeded its time limit; no index changes committed.")
        }
    }
}
