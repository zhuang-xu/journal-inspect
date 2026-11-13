import Foundation
import XCTest

@testable import JournalCore

final class JournalCancellationTests: XCTestCase {
    func testCancellationDuringDirectScanRollsBackWithoutCreatingSnapshot() async throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        try journal.populateEntries(count: 500)
        let reader = JournalReader(sourceURL: journal.sourceURL)
        let destination = journal.indexDirectory
        let before = try JournalTestFixture.snapshotDirectories()
        let task = Task {
            try reader.synchronize(to: destination) { count in
                if count >= 250 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM entries"), "1")
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM scan_seen"), "0")
        let after = try JournalTestFixture.snapshotDirectories()
        XCTAssertEqual(before, after)
    }

    func testCancellationPreservesIndex() async throws {
        let journal = try JournalTestFixture()
        _ = try journal.synchronize()
        let reader = JournalReader(sourceURL: journal.sourceURL)
        let destination = journal.indexDirectory
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try reader.synchronize(to: destination)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM entries"), "1")
    }
}
