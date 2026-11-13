import Foundation
import XCTest

@testable import JournalCore

final class JournalInfrastructureTests: XCTestCase {
    func testPrivateStoreRepairsExistingPermissionsAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let file = try PrivateStoreFile.prepare(in: directory, named: "test.sqlite3")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = try PrivateStoreFile.prepare(in: directory, named: "test.sqlite3")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? Int,
            0o700)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int,
            0o600)

        let link = directory.appendingPathComponent("link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PrivateStoreFile.prepare(in: directory, named: "link.sqlite3"))
        let directoryLink = root.appendingPathComponent("linked-store")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        XCTAssertThrowsError(try PrivateStoreFile.prepare(in: directoryLink, named: "test.sqlite3"))
    }

    func testAlreadyCancelledWorkerDoesNotRunOperation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await journalWorker {
                XCTFail("Cancelled work must not open a database")
                return 1
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testCancellationReachesRunningWorker() async throws {
        let started = expectation(description: "worker started")
        let task = Task {
            try await journalWorker {
                started.fulfill()
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                // A cancelled parent alone must not make this assertion pass.
                XCTAssertTrue(Task.isCancelled)
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled worker returned a result")
        } catch is CancellationError {}
    }
}
