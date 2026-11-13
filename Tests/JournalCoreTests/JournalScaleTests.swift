import Foundation
import XCTest

@testable import JournalCore

final class JournalScaleTests: XCTestCase {
    func testLargeCollectionStreamsEveryEntry() throws {
        let journal = try JournalTestFixture()
        try journal.populateEntries(count: 10000, includeAssets: true)
        let result = try journal.synchronize()
        XCTAssertEqual(result.seen, 10000)
        XCTAssertEqual(result.changed, 10000)
        XCTAssertEqual(try journal.synchronize().changed, 0)
        XCTAssertEqual(try journal.openIndex().scalar("SELECT count(*) FROM entries"), "10000")
    }
}
