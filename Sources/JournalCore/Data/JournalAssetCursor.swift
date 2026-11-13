/// Keeps a single look-ahead asset row while entries are visited in source-row order.
struct JournalAssetCursor {
    private let statement: Statement
    private let entryColumn: Int32
    private var hasCurrentRow: Bool

    init(database: Database) throws {
        statement = try Statement(
            database,
            """
            SELECT asset.* FROM temp.asset_order AS ordered INDEXED BY asset_order_index
            CROSS JOIN ZJOURNALENTRYASSETMO AS asset ON asset.Z_PK=ordered.row_id
            ORDER BY ordered.entry, ordered.row_id
            """)
        entryColumn = try statement.columnIndex(named: "ZENTRY")
        hasCurrentRow = try statement.next()
    }

    private var entryRowID: Int64 { statement.integer(entryColumn) }

    mutating func appendAssets(for entryRowID: Int64, to fingerprint: inout EntryFingerprint) throws
    {
        // Skip orphan assets, including those whose entry has been permanently removed.
        while hasCurrentRow && self.entryRowID < entryRowID {
            try advance()
        }

        while hasCurrentRow && self.entryRowID == entryRowID {
            try Task.checkCancellation()
            fingerprint.append(statement)
            try advance()
        }
    }

    private mutating func advance() throws {
        try Task.checkCancellation()
        hasCurrentRow = try statement.next()
    }
}
