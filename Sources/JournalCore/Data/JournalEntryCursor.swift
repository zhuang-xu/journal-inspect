import Foundation

/// Resolves the private schema once, then exposes metadata for the current entry.
struct JournalEntryCursor {
    let statement: Statement
    private let columns: Columns

    private struct Columns {
        let rowID: Int32
        let uuid: Int32
        let created: Int32
        let modified: Int32
        let entryDate: Int32
        let recentlyDeleted: Int32
        let fullyRemoved: Int32

        init(statement: Statement) throws {
            rowID = try statement.columnIndex(named: "Z_PK")
            uuid = try statement.columnIndex(named: "ZID")
            created = try statement.columnIndex(named: "ZCREATEDDATE")
            modified = try statement.columnIndex(named: "ZUPDATEDDATE")
            entryDate = try statement.columnIndex(named: "ZENTRYDATE")
            recentlyDeleted = try statement.columnIndex(named: "ZRECENTLYDELETED")
            fullyRemoved = try statement.columnIndex(named: "ZISFULLYREMOVED")
        }
    }

    init(database: Database) throws {
        statement = try Statement(database, "SELECT * FROM ZJOURNALENTRYMO ORDER BY Z_PK")
        columns = try Columns(statement: statement)
    }

    var rowID: Int64 { statement.integer(columns.rowID) }

    func advance() throws -> Bool {
        try statement.next()
    }

    func metadata(sourceID: String, fingerprint: String) throws -> JournalEntry {
        guard let uuid = statement.uuid(columns.uuid) else {
            throw JournalReaderError(message: "Invalid Journal entry UUID.")
        }

        return JournalEntry(
            sourceID: sourceID,
            uuid: uuid.uuidString.lowercased(),
            created: statement.number(columns.created),
            modified: statement.number(columns.modified),
            entryDate: statement.number(columns.entryDate),
            fingerprint: fingerprint,
            deleted: statement.integer(columns.recentlyDeleted) != 0
                || statement.integer(columns.fullyRemoved) != 0
        )
    }
}
