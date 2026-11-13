import Foundation
import XCTest

@testable import JournalCore

final class JournalSynchronizationTests: XCTestCase {
    func testStoreReplacementDoesNotDeleteOtherNamespace() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.source.execute(
            "UPDATE Z_METADATA SET Z_UUID='ffeeddcc-bbaa-9988-7766-554433221100'")
        _ = try journal.synchronize()
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM sources"), "2")
        XCTAssertEqual(
            try journal.openIndex().scalar("SELECT count(*) FROM entries WHERE is_deleted=0"), "2")
    }

    func testFirstScanIndexesEveryEntry() throws {
        let journal = try JournalTestFixture()
        let result = try journal.synchronize()
        XCTAssertEqual(result.seen, 1)
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(result.removed, 0)
    }

    func testUnchangedEntriesAreNotReportedAgain() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        XCTAssertEqual(try journal.synchronize().changed, 0)
    }

    func testBodyEditIsDetectedWithoutUpdatingTimestamp() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.editBody()
        XCTAssertEqual(try journal.synchronize().changed, 1)
    }

    func testNewAssetIsDetected() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.addAsset()
        XCTAssertEqual(try journal.synchronize().changed, 1)
    }

    func testAssetEditIsDetected() throws {
        let journal = try JournalTestFixture()
        try journal.addAsset()
        _ = try journal.synchronize()
        try journal.source.execute("UPDATE ZJOURNALENTRYASSETMO SET Z_OPT=2")
        XCTAssertEqual(try journal.synchronize().changed, 1)
    }

    func testSoftDeletedEntryIsMarkedDeleted() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.setDeleted(true)
        _ = try journal.synchronize()
        XCTAssertEqual(try journal.openIndex().scalar("SELECT is_deleted FROM entries"), "1")
    }

    func testRestoredEntryBecomesActive() throws {
        let journal = try JournalTestFixture()
        try journal.setDeleted(true)
        _ = try journal.synchronize()
        try journal.setDeleted(false)
        XCTAssertEqual(try journal.synchronize().changed, 1)
        XCTAssertEqual(try journal.openIndex().scalar("SELECT is_deleted FROM entries"), "0")
    }

    func testMissingEntryIsRemovedOnlyOnce() throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.source.execute("DELETE FROM ZJOURNALENTRYMO")
        XCTAssertEqual(try journal.synchronize().removed, 1)
        XCTAssertEqual(try journal.synchronize().removed, 0)
    }
}
