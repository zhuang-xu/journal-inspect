import Foundation

@testable import JournalCore

/// Synthetic Journal store and metadata directory, isolated for each test.
/// Never opens the real Apple Journal store.
final class JournalTestFixture {
    let directory: URL
    let sourceURL: URL
    let indexDirectory: URL
    let source: Database

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        sourceURL = directory.appendingPathComponent("source.sqlite")
        indexDirectory = directory.appendingPathComponent("index")
        source = try Database(sourceURL.path, readOnly: false)
        try source.execute(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE Z_METADATA(Z_UUID TEXT);
            INSERT INTO Z_METADATA VALUES('00112233-4455-6677-8899-aabbccddeeff');
            CREATE TABLE ZJOURNALENTRYMO(Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZTEXT BLOB,
                ZTITLE BLOB,ZCREATEDDATE REAL,ZUPDATEDDATE REAL,ZENTRYDATE REAL,
                ZRECENTLYDELETED INTEGER,ZISFULLYREMOVED INTEGER);
            CREATE TABLE ZJOURNALENTRYASSETMO(Z_PK INTEGER PRIMARY KEY,ZENTRY INTEGER,ZID BLOB,Z_OPT INTEGER);
            INSERT INTO ZJOURNALENTRYMO VALUES(1,X'00112233445566778899AABBCCDDEEFF',
                'PRIVATE_BODY_SENTINEL','PRIVATE_TITLE_SENTINEL',1,2,3,0,0);
            """)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func synchronize() throws -> SyncResult {
        try JournalReader(sourceURL: sourceURL).synchronize(to: indexDirectory)
    }

    func openIndex() throws -> Database {
        try Database(
            indexDirectory.appendingPathComponent("journal-index.sqlite3").path, readOnly: true)
    }

    func editBody() throws {
        try source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='EDITED'")
    }

    func addAsset() throws {
        try source.execute("INSERT INTO ZJOURNALENTRYASSETMO VALUES(1,1,randomblob(16),1)")
    }

    func setDeleted(_ deleted: Bool) throws {
        try source.execute("UPDATE ZJOURNALENTRYMO SET ZRECENTLYDELETED=\(deleted ? 1 : 0)")
    }

    func populateEntries(count: Int, includeAssets: Bool = false) throws {
        precondition(count >= 2)
        try source.execute(
            """
            WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x<\(count))
            INSERT INTO ZJOURNALENTRYMO
                SELECT x,randomblob(16),zeroblob(256),NULL,1,2,3,0,0 FROM n;
            """)
        if includeAssets {
            try source.execute(
                """
                INSERT INTO ZJOURNALENTRYASSETMO
                    SELECT Z_PK,Z_PK,randomblob(16),1 FROM ZJOURNALENTRYMO
                """)
        }
    }

    static func snapshotDirectories() throws -> Set<String> {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path)
        return Set(names.filter { $0.hasPrefix("journal-inspect-private-") })
    }

}
