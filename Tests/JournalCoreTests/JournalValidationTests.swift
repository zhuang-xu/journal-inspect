import CryptoKit
import Foundation
import XCTest

@testable import JournalCore

final class JournalValidationTests: XCTestCase {
    func testInvalidIdentityRollsBackWithoutFalseDeletion() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.source.execute(
            "INSERT INTO ZJOURNALENTRYMO SELECT 2,ZID,ZTEXT,ZTITLE,1,2,3,0,0 FROM ZJOURNALENTRYMO")
        XCTAssertThrowsError(try journal.synchronize())
        XCTAssertEqual(
            try journal.openIndex().scalar("SELECT count(*) FROM entries WHERE is_deleted=0"), "1")
        XCTAssertEqual(
            try journal.openIndex().scalar("SELECT count(*) FROM sync_runs WHERE status='failed'"),
            "1")
        try journal.source.execute("UPDATE ZJOURNALENTRYMO SET ZID=NULL WHERE Z_PK=2")
        XCTAssertThrowsError(try journal.synchronize())
    }

    func testUnsupportedSchemaAndMissingSource() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.source.execute("DROP TABLE ZJOURNALENTRYASSETMO")
        XCTAssertThrowsError(try journal.synchronize())
        XCTAssertEqual(try journal.openIndex().scalar("SELECT is_deleted FROM entries"), "0")
        let missing = journal.directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(
            try JournalReader(sourceURL: missing).synchronize(to: journal.indexDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUnknownDestinationRejectedAndLegacyTextUntouched() throws {
        let journal = try JournalTestFixture()
        try FileManager.default.createDirectory(
            at: journal.indexDirectory, withIntermediateDirectories: false)
        let target = journal.indexDirectory.appendingPathComponent("journal-index.sqlite3")
        let foreign = try Database(target.path, readOnly: false)
        try foreign.execute("CREATE TABLE secret(text TEXT); INSERT INTO secret VALUES('legacy')")
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try journal.synchronize())
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testForeignEmptyDatabaseIsRejected() throws {
        let journal = try JournalTestFixture()
        try FileManager.default.createDirectory(
            at: journal.indexDirectory, withIntermediateDirectories: false)
        let target = journal.indexDirectory.appendingPathComponent("journal-index.sqlite3")
        let foreign = try Database(target.path, readOnly: false)
        try foreign.execute("PRAGMA application_id=12345")
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try JournalMetadataStore(directory: journal.indexDirectory))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testUnsupportedMetadataVersionIsRejectedWithoutMutation() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        let target = journal.indexDirectory.appendingPathComponent("journal-index.sqlite3")
        let future = try Database(target.path, readOnly: false)
        try future.execute("PRAGMA user_version=999")
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try JournalMetadataStore(directory: journal.indexDirectory))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testMissingColumnReturnsAnError() throws {
        let journal = try JournalTestFixture()
        let statement = try Statement(journal.source, "SELECT Z_UUID FROM Z_METADATA")
        XCTAssertThrowsError(try statement.columnIndex(named: "MISSING"))
    }
    func testReadOnlyConnectionRejectsSourceWrites() throws {
        let journal = try JournalTestFixture()
        let reader = try Database(journal.sourceURL.path, readOnly: true)
        XCTAssertThrowsError(try reader.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='FORBIDDEN'"))
    }

    func testReadDeadlinePreservesExistingIndex() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        let reader = JournalReader(sourceURL: journal.sourceURL, maximumReadDuration: 0)
        XCTAssertThrowsError(try reader.synchronize(to: journal.indexDirectory))
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM entries"), "1")
    }

    func testConcurrentWALWriteAppearsOnlyOnNextScan() throws {
        let journal = try JournalTestFixture()
        try journal.populateEntries(count: 500)
        let reader = JournalReader(sourceURL: journal.sourceURL)
        let result = try reader.synchronize(to: journal.indexDirectory) { count in
            if count == 250 {
                // A different connection writes while the read transaction stays open.
                // Failure changes the next-scan assertion, without swallowing a test failure.
                try? journal.source.execute(
                    """
                    UPDATE ZJOURNALENTRYMO SET ZTEXT='CONCURRENT_EDIT' WHERE Z_PK=1;
                    INSERT INTO ZJOURNALENTRYMO VALUES(501,randomblob(16),'NEW',NULL,1,2,3,0,0)
                    """)
            }
        }
        XCTAssertEqual(result.seen, 500)
        let next = try journal.synchronize()
        XCTAssertEqual(next.seen, 501)
        XCTAssertEqual(next.changed, 2)
    }

}

final class JournalBrowsingTests: XCTestCase {
    func testPaginationDateBoundsAndDeletedRows() throws {
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 123)
        _ = try fixture.synchronize()
        let store = try JournalMetadataStore(directory: fixture.indexDirectory)
        var identities = Set<String>()
        var offset: Int? = 0
        while let current = offset {
            let page = try store.browse(limit: 20, offset: current)
            XCTAssertEqual(page.total, 123)
            for entry in page.entries { XCTAssertTrue(identities.insert(entry.id).inserted) }
            offset = page.nextOffset
        }
        XCTAssertEqual(identities.count, 123)
        XCTAssertEqual(
            try store.browse(
                start: Date(timeIntervalSinceReferenceDate: 3),
                end: Date(timeIntervalSinceReferenceDate: 4)
            ).total, 123)
        XCTAssertEqual(try store.browse(end: Date(timeIntervalSinceReferenceDate: 3)).total, 0)
        XCTAssertEqual(try store.browse(start: Date(timeIntervalSinceReferenceDate: 4)).total, 0)
        XCTAssertTrue(try store.browse(offset: 999).entries.isEmpty)
        XCTAssertThrowsError(try store.browse(limit: 0))
        XCTAssertThrowsError(try store.browse(offset: -1))
        try fixture.setDeleted(true)
        _ = try fixture.synchronize()
        XCTAssertEqual(try store.browse().total, 0)
        XCTAssertEqual(try store.browse(includeDeleted: true).total, 123)
    }

    func testOnDemandCurrentTextLargeRTFAndMissingEntries() throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let reader = JournalReader(sourceURL: fixture.sourceURL)
        let store = try JournalMetadataStore(directory: fixture.indexDirectory)
        let entry = try XCTUnwrap(try store.browse().entries.first)
        XCTAssertEqual(
            try reader.openEntry(uuid: entry.uuid, sourceID: entry.sourceID).text,
            "PRIVATE_BODY_SENTINEL")
        try fixture.editBody()
        XCTAssertEqual(try reader.openEntry(uuid: entry.uuid).text, "EDITED")
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTEXT=CAST(zeroblob(4194304) AS TEXT)")
        XCTAssertEqual(try reader.openEntry(uuid: entry.uuid).text.utf8.count, 4_194_304)
        let update = try Statement(fixture.source, "UPDATE ZJOURNALENTRYMO SET ZTEXT=?")
        try update.execute(["{\\rtf1\\ansi Hello \\b Journal\\b0 .}"])
        XCTAssertEqual(try reader.openEntry(uuid: entry.uuid).text, "Hello Journal.")
        try fixture.setDeleted(true)
        XCTAssertThrowsError(try reader.openEntry(uuid: entry.uuid))
        try fixture.source.execute("DELETE FROM ZJOURNALENTRYMO")
        XCTAssertThrowsError(try reader.openEntry(uuid: entry.uuid))
        XCTAssertThrowsError(try reader.openEntry(uuid: UUID().uuidString))
        XCTAssertThrowsError(try reader.openEntry(uuid: "invalid"))
        XCTAssertThrowsError(try reader.openEntry(uuid: entry.uuid, sourceID: UUID().uuidString))
    }

    func testFailureBeforeScanStillRecordsStatusAndPreservesSuccess() throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let store = try JournalMetadataStore(directory: fixture.indexDirectory)
        let first = try store.syncStatus()
        XCTAssertEqual(first.state, "succeeded")
        XCTAssertEqual(first.changed, 1)
        let missing = fixture.directory.appendingPathComponent("absent.sqlite")
        XCTAssertThrowsError(
            try JournalReader(sourceURL: missing).synchronize(to: fixture.indexDirectory))
        let failed = try store.syncStatus()
        XCTAssertEqual(failed.state, "failed")
        XCTAssertEqual(failed.lastSuccessfulSync, first.lastSuccessfulSync)
        XCTAssertEqual(failed.errorCode, "source_unavailable")
        _ = try fixture.synchronize()
        XCTAssertEqual(try store.syncStatus().changed, 0)
        store.recordSyncFailure(JournalReaderError(message: "private", code: "permission_denied"))
        XCTAssertEqual(try store.syncStatus().errorCode, "permission_denied")
    }

    func testCancellationBeforeSourceOpenIsRecorded() async throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let directory = fixture.indexDirectory
        let reader = JournalReader(sourceURL: fixture.sourceURL)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try reader.synchronize(to: directory)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let status = try JournalMetadataStore(directory: directory).syncStatus()
        XCTAssertEqual(status.errorCode, "cancelled")
        XCTAssertNotNil(status.lastSuccessfulSync)
    }

    func testFilesystemPermissionDenialIsRecorded() throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        // Use a distinct inode so SQLite cannot reuse the fixture's already-open file handle.
        let denied = fixture.directory.appendingPathComponent("denied.sqlite")
        try FileManager.default.copyItem(at: fixture.sourceURL, to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: denied.path)
        }
        XCTAssertThrowsError(
            try JournalReader(sourceURL: denied).synchronize(to: fixture.indexDirectory)
        ) { error in
            XCTAssertEqual((error as? JournalReaderError)?.code, "permission_denied")
        }
        let status = try JournalMetadataStore(directory: fixture.indexDirectory).syncStatus()
        XCTAssertEqual(status.errorCode, "permission_denied")
        XCTAssertNotNil(status.lastSuccessfulSync)
    }

    /// Explicit opt-in only: real private text is read in memory, never printed or saved.
    func testLiveJournalFlow() throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_INSPECT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set JOURNAL_INSPECT_LIVE_TEST=1 to verify the real Journal read-only.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = JournalReader()
        func signatures() throws -> [Data] {
            try [reader.sourceURL, URL(fileURLWithPath: reader.sourceURL.path + "-wal")].map {
                guard FileManager.default.fileExists(atPath: $0.path) else { return Data() }
                return Data(SHA256.hash(data: try Data(contentsOf: $0)))
            }
        }
        let before = try signatures()
        let first = try reader.synchronize(to: directory)
        let repeatScan = try reader.synchronize(to: directory)
        XCTAssertEqual(repeatScan.changed, 0)
        let store = try JournalMetadataStore(directory: directory)
        var offset: Int? = 0
        var loaded = 0
        var unavailable = 0
        var largest = 0
        while let current = offset {
            let page = try store.browse(limit: 37, offset: current, includeDeleted: true)
            XCTAssertEqual(page.total, first.seen)
            for entry in page.entries {
                if entry.deleted {
                    XCTAssertThrowsError(
                        try reader.openEntry(uuid: entry.uuid, sourceID: entry.sourceID))
                    unavailable += 1
                } else {
                    let body = try reader.openEntry(uuid: entry.uuid, sourceID: entry.sourceID)
                    largest = max(largest, body.text.utf8.count)
                    loaded += 1
                    if let time = entry.entryDate ?? entry.created {
                        let date = Date(timeIntervalSinceReferenceDate: time)
                        XCTAssertGreaterThan(
                            try store.browse(
                                start: date,
                                end: date.addingTimeInterval(1)
                            ).total, 0)
                    }
                }
            }
            offset = page.nextOffset
        }
        XCTAssertThrowsError(try reader.openEntry(uuid: UUID().uuidString))
        XCTAssertNotNil(try store.syncStatus().lastSuccessfulSync)
        XCTAssertEqual(try signatures(), before, "Source DB/WAL changed during verification")
        print(
            "LIVE: indexed=\(first.seen), loaded=\(loaded), deleted=\(unavailable), largest_utf8_bytes=\(largest), repeat_changes=\(repeatScan.changed)"
        )
    }
}
