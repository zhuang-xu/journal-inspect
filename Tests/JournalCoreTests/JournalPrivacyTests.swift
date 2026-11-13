import Foundation
import XCTest

@testable import JournalCore

final class JournalPrivacyTests: XCTestCase {
    func testReadingDoesNotModifySourceDatabaseOrWAL() throws {
        let journal = try JournalTestFixture()
        let wal = URL(fileURLWithPath: journal.sourceURL.path + "-wal")
        let databaseBefore = try Data(contentsOf: journal.sourceURL)
        let walBefore = try Data(contentsOf: wal)

        _ = try journal.synchronize()

        XCTAssertEqual(try Data(contentsOf: journal.sourceURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
    }

    func testIndexFilesNeverContainBodyOrTitle() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()

        let files = try FileManager.default.contentsOfDirectory(
            at: journal.indexDirectory, includingPropertiesForKeys: nil)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertNil(data.range(of: Data("PRIVATE_BODY_SENTINEL".utf8)))
            XCTAssertNil(data.range(of: Data("PRIVATE_TITLE_SENTINEL".utf8)))
        }
    }

    func testIndexFileIsAccessibleOnlyToItsOwner() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()

        let path = journal.indexDirectory.appendingPathComponent("journal-index.sqlite3").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testSuccessfulScanClearsWorkingIDsAndRecordsCompletion() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()

        let index = try journal.openIndex()
        XCTAssertEqual(try index.scalar("SELECT count(*) FROM scan_seen"), "0")
        XCTAssertEqual(
            try index.scalar("SELECT count(*) FROM sync_runs WHERE status='succeeded'"), "1")
    }
}
