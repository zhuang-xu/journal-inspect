import CryptoKit
import Foundation
import XCTest

@testable import JournalCore

final class JournalFingerprintTests: XCTestCase {
    func testFingerprintFormatIsUnchanged() throws {
        let journal = try JournalTestFixture()
        try journal.source.execute(
            """
            CREATE TEMP TABLE asset_order(entry INTEGER, row_id INTEGER PRIMARY KEY);
            INSERT INTO asset_order SELECT ZENTRY,Z_PK FROM ZJOURNALENTRYASSETMO;
            CREATE INDEX temp.asset_order_index ON asset_order(entry,row_id);
            """)
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let reader = JournalReader(sourceURL: journal.sourceURL)
        var fingerprints: [String] = []
        _ = try reader.stream(source: journal.source, key: key) { entry in
            fingerprints.append(entry.fingerprint)
        }
        // Captured from the implementation before the readability refactor.
        XCTAssertEqual(
            fingerprints,
            [
                "3348a7d2389953a95ec604be3c1d2ac5bd28b23e4b028cf9da51b8a49ef8744d"
            ])
    }
}
