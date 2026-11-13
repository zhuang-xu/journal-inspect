import Foundation
import XCTest

@testable import JournalCore

final class PersonalMemoryTests: XCTestCase {
    private let fact = MemoryCandidate(
        statement: "Preparing for interviews", category: .goal, quote: "PRIVATE_BODY_SENTINEL")
    private func setup() async throws -> (
        JournalTestFixture, PersonalMemoryStore, JournalEntry, UUID
    ) {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let store = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"))
        try await store.setEnabled(true)
        let entry = try JournalMetadataStore(directory: fixture.indexDirectory).browse().entries[0]
        let generation = try await store.beginUpdate(entries: [entry])
        return (fixture, store, entry, generation)
    }
    func testBuiltMemoriesAutomaticallySupplyBackgroundWithoutClaimingConfirmation() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact, fact], version: "v1",
            generation: generation)
        var records = try await store.snapshot().records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sources.count, 1)
        XCTAssertEqual(records[0].state, .unreviewed)
        let before = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertTrue(before.text.contains(fact.statement))
        XCTAssertTrue(before.text.contains("automatic_unconfirmed"))
        try await store.approve(records[0].id)
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertTrue(profile.text.contains(fact.statement))
        XCTAssertTrue(profile.text.contains("\"review\":\"confirmed\""))
        let reopened = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"))
        records = try await reopened.snapshot().records
        XCTAssertEqual(records.count, 1)
        let url = fixture.directory.appendingPathComponent("memory/personal-memory.sqlite3")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let indexData = try Data(
            contentsOf: fixture.indexDirectory.appendingPathComponent("journal-index.sqlite3"))
        XCTAssertNil(indexData.range(of: Data(fact.statement.utf8)))
    }
    func testLegacySuggestionQueueMigratesToAutomaticBackgroundNotConfirmed() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1",
            generation: generation)
        try await store.save(statement: "My own correction", category: .goal, asOf: Date())
        try await store.save(statement: "An outdated user fact", category: .goal, asOf: Date())
        let outdatedID = try await store.snapshot().records.last!.id
        try await store.markOutdated(outdatedID)
        let db = try Database(
            fixture.directory.appendingPathComponent("memory/personal-memory.sqlite3").path,
            readOnly: false)
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(db.scalar("SELECT value FROM memory_state WHERE id=1").utf8))
                as? [String: Any])
        state.removeValue(forKey: "backgroundPolicyVersion")
        var records = try XCTUnwrap(state["records"] as? [[String: Any]])
        records[0]["state"] = "awaitingClarification"
        state["records"] = records
        let data = try JSONSerialization.data(withJSONObject: state)
        try Statement(db, "UPDATE memory_state SET value=? WHERE id=1").execute([
            String(decoding: data, as: UTF8.self)
        ])
        let migrated = try await store.snapshot()
        XCTAssertEqual(migrated.records[0].state, .unreviewed)
        XCTAssertEqual(migrated.records[0].origin, .automatic)
        XCTAssertEqual(migrated.records[1].state, .active)
        XCTAssertEqual(migrated.records[2].state, .outdated)
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertTrue(profile.text.contains(fact.statement))
        XCTAssertTrue(profile.text.contains("My own correction"))
        XCTAssertFalse(profile.text.contains("An outdated user fact"))
        try await store.setEnabled(false)
        let disabled = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertEqual(disabled.text, "[]")
        let reopened = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"))
        let saved = try await reopened.snapshot()
        XCTAssertEqual(saved.records[0].state, .unreviewed)
    }

    func testExplicitClarificationStillExcludedUnderNewPolicy() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1",
            generation: generation)
        let db = try Database(
            fixture.directory.appendingPathComponent("memory/personal-memory.sqlite3").path,
            readOnly: false)
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(db.scalar("SELECT value FROM memory_state WHERE id=1").utf8))
                as? [String: Any])
        var records = try XCTUnwrap(state["records"] as? [[String: Any]])
        records[0]["state"] = "awaitingClarification"
        state["records"] = records
        let data = try JSONSerialization.data(withJSONObject: state)
        try Statement(db, "UPDATE memory_state SET value=? WHERE id=1").execute([
            String(decoding: data, as: UTF8.self)
        ])
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertEqual(profile.text, "[]")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records[0].state, .awaitingClarification)
    }

    func testRecentMemoriesBreakExactRelevanceTies() async throws {
        let (fixture, store, _, _) = try await setup()
        try await store.save(
            statement: "Older " + String(repeating: "a", count: 300), category: .goal,
            asOf: Date(timeIntervalSince1970: 1))
        try await store.save(
            statement: "Recent " + String(repeating: "b", count: 300), category: .goal,
            asOf: Date(timeIntervalSince1970: 2))
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertTrue(profile.text.contains("Recent"))
        XCTAssertTrue(profile.text.contains("Older"))
        let rows =
            try JSONSerialization.jsonObject(with: Data(profile.text.utf8)) as! [[String: Any]]
        XCTAssertTrue((rows[0]["statement"] as? String)?.hasPrefix("Recent") == true)
        XCTAssertEqual(profile.omittedCount, 0)
    }

    func testUnsyncedEditsAndDeletionExcludeAutomaticFacts() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1",
            generation: generation)
        let record = try await store.snapshot().records[0]
        try await store.approve(record.id)
        try fixture.editBody()
        let stale = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertEqual(stale.text, "[]")
        _ = try fixture.synchronize()
        let changed = try JournalMetadataStore(directory: fixture.indexDirectory).browse().entries
        _ = try await store.beginUpdate(entries: changed)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records[0].state, .outdated)
        try fixture.setDeleted(true)
        _ = try fixture.synchronize()
        _ = try await store.beginUpdate(entries: [])
        let deleted = try await store.snapshot()
        XCTAssertTrue(deleted.records[0].sources.isEmpty)
    }
    func testCorrectionsSurviveReprocessingChangedSource() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1",
            generation: generation)
        let id = try await store.snapshot().records[0].id
        try await store.save(
            id: id, statement: "My corrected goal", category: .goal,
            asOf: Date(timeIntervalSince1970: 42))
        try fixture.editBody()
        _ = try fixture.synchronize()
        let changed = try JournalMetadataStore(directory: fixture.indexDirectory).browse().entries[
            0]
        let next = try await store.beginUpdate(entries: [changed])
        try await store.replace(
            entry: changed, text: "EDITED",
            candidates: [
                MemoryCandidate(statement: "A model rewrite", category: .goal, quote: "EDITED")
            ], version: "v2", generation: next)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records[0].statement, "My corrected goal")
        XCTAssertEqual(snapshot.records[0].origin, .user)
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertTrue(profile.text.contains("My corrected goal"))
    }
    func testForgetSuppressionRestoreAndDeleteAll() async throws {
        let (fixture, store, entry, generation) = try await setup()
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1",
            generation: generation)
        let id = try await store.snapshot().records[0].id
        try await store.forget(id)
        var next = try await store.beginUpdate(entries: [entry])
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1", generation: next)
        let suppressed = try await store.snapshot()
        XCTAssertTrue(suppressed.records.isEmpty)
        try await store.restoreSuggestions()
        next = try await store.beginUpdate(entries: [entry])
        try await store.replace(
            entry: entry, text: fact.quote, candidates: [fact], version: "v1", generation: next)
        let restored = try await store.snapshot()
        XCTAssertEqual(restored.records.count, 1)
        try await store.deleteAll()
        let cleared = try await store.snapshot()
        XCTAssertTrue(cleared.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }
    func testInvalidOutputIsAtomicAndDisabledRejectsInFlightCommit() async throws {
        let (fixture, store, entry, generation) = try await setup()
        defer { withExtendedLifetime(fixture) {} }

        do {
            try await store.replace(
                entry: entry, text: fact.quote,
                candidates: [
                    fact, MemoryCandidate(statement: "Invented", category: .goal, quote: "absent"),
                ], version: "v1", generation: generation)
            XCTFail("Invalid source quote accepted")
        } catch PersonalMemoryError.invalidCandidate {}
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        try await store.setEnabled(false)
        do {
            try await store.replace(
                entry: entry, text: fact.quote, candidates: [fact], version: "v1",
                generation: generation)
            XCTFail("Disabled memory accepted an update")
        } catch PersonalMemoryError.staleUpdate {}
        let profile = try await store.fixtureProfile()
        XCTAssertEqual(profile.text, "[]")
    }
    func testAllRelevantCandidatesReachTokenizerAndPersistWhenDisabled() async throws {
        let (fixture, store, _, _) = try await setup()
        for i in 0..<20 {
            try await store.save(
                statement: "Goal \(i): " + String(repeating: "学", count: 50), category: .goal,
                asOf: Date())
        }
        let profile = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertGreaterThan(profile.text.utf8.count, 3600)
        let rows =
            try JSONSerialization.jsonObject(with: Data(profile.text.utf8)) as! [[String: Any]]
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(profile.omittedCount, 0)
        try await store.setEnabled(false)
        let disabled = try await store.fixtureProfile(sourceURL: fixture.sourceURL)
        XCTAssertEqual(disabled.text, "[]")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 20)
    }
    func testDateOnlyRevisionIsReprocessed() async throws {
        let (fixture, store, _, _) = try await setup()
        let extractor = FixtureMemoryExtractor()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: extractor, sourceURL: fixture.sourceURL,
            indexDirectory: fixture.indexDirectory)
        try await updater.update()
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZENTRYDATE=500")
        _ = try fixture.synchronize()
        try await updater.update()
        let calls = await extractor.calls
        XCTAssertEqual(calls, 2)
        let record = try await store.snapshot().records[0]
        XCTAssertEqual(record.sources.count, 1)
        XCTAssertEqual(record.asOf, Date(timeIntervalSinceReferenceDate: 500))
        try await store.markOutdated(record.id)
        try await updater.update(forceExtraction: true)
        let outdated = try await store.snapshot().records[0]
        XCTAssertEqual(outdated.state, .outdated)
    }

    func testFullBuildReextractsCheckpointedEntriesAndDisplaysSourceLinkedFacts() async throws {
        let (fixture, store, _, _) = try await setup()
        let empty = PersonalMemoryUpdater(
            store: store, extractor: EmptyMemoryExtractor(),
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        try await empty.update()
        let extractor = FixtureMemoryExtractor()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: extractor,
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        try await updater.update(forceExtraction: true)
        try await updater.update(forceExtraction: true)
        let calls = await extractor.calls
        XCTAssertEqual(
            calls, 2, "An explicit full build must not skip previously processed entries")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records[0].sources.count, 1)
        XCTAssertEqual(snapshot.records[0].state, .unreviewed)
        XCTAssertEqual(snapshot.lastBuild?.unchangedEntries, 0)
        XCTAssertEqual(snapshot.lastBuild?.extractedEntries, 1)
    }

    func testEmptyExtractionAndUnchangedRunsHaveDistinctPersistentReports() async throws {
        let (fixture, store, _, _) = try await setup()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: EmptyMemoryExtractor(),
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        try await updater.update()
        let first = try await store.snapshot()
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertEqual(first.processedEntryCount, 1)
        XCTAssertEqual(first.lastBuild?.status, .completed)
        XCTAssertEqual(first.lastBuild?.totalEntries, 1)
        XCTAssertEqual(first.lastBuild?.completedEntries, 1)
        XCTAssertEqual(first.lastBuild?.extractedEntries, 1)
        XCTAssertEqual(first.lastBuild?.unchangedEntries, 0)
        XCTAssertEqual(first.lastBuild?.candidateCount, 0)
        XCTAssertEqual(first.lastBuild?.nonemptyEntries, 1)
        XCTAssertEqual(first.lastBuild?.decodedTextBytes, "PRIVATE_BODY_SENTINEL".utf8.count)
        XCTAssertEqual(first.lastBuild?.zeroCandidateEntries, 1)
        XCTAssertNotNil(first.lastBuild?.finishedAt)
        try await updater.update()
        let reopened = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"))
        let second = try await reopened.snapshot()
        XCTAssertEqual(second.lastBuild?.extractedEntries, 0)
        XCTAssertEqual(second.lastBuild?.unchangedEntries, 1)
        XCTAssertEqual(second.processedEntryCount, 1)
        XCTAssertTrue(second.records.isEmpty)
    }

    func testEarlierMemoryStateWithoutBuildReportStillLoads() async throws {
        let (fixture, store, _, _) = try await setup()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: EmptyMemoryExtractor(),
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        try await updater.update()
        let db = try Database(
            fixture.directory.appendingPathComponent("memory/personal-memory.sqlite3").path,
            readOnly: false)
        let json = try db.scalar("SELECT value FROM memory_state WHERE id=1")
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        state.removeValue(forKey: "lastBuild")
        let data = try JSONSerialization.data(withJSONObject: state)
        try Statement(db, "UPDATE memory_state SET value=? WHERE id=1").execute([
            String(decoding: data, as: UTF8.self)
        ])
        let migrated = try await store.snapshot()
        XCTAssertTrue(migrated.enabled)
        XCTAssertEqual(migrated.processedEntryCount, 1)
        XCTAssertNil(migrated.lastBuild)
    }

    func testTaskCancellationPersistsAggregateReportWithoutFacts() async throws {
        let (fixture, store, _, _) = try await setup()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: CancellingMemoryExtractor(),
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        let task = Task { try await updater.update() }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.lastBuild?.status, .cancelled)
        XCTAssertNotNil(snapshot.lastBuild?.finishedAt)
        XCTAssertEqual(snapshot.processedEntryCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    func testFailedExtractionReportsIncompleteWithoutCheckpoint() async throws {
        let (fixture, store, _, _) = try await setup()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: InvalidMemoryExtractor(),
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        try await updater.update()
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.lastBuild?.status, .failed)
        XCTAssertEqual(snapshot.lastBuild?.completedEntries, 1)
        XCTAssertEqual(snapshot.lastBuild?.failedEntries, 1)
        XCTAssertEqual(snapshot.processedEntryCount, 0)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    func testInterruptedUpdateResumesCompletedEntryCheckpoints() async throws {
        let (fixture, store, _, _) = try await setup()
        try fixture.populateEntries(count: 3)
        // Give every synthetic body a decodable nonempty text value.
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='A durable goal'")
        _ = try fixture.synchronize()
        let extractor = InterruptingExtractor()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: extractor, sourceURL: fixture.sourceURL,
            indexDirectory: fixture.indexDirectory)
        do {
            try await updater.update()
            XCTFail("Expected interruption")
        } catch is CancellationError {}
        let interrupted = try await store.snapshot()
        XCTAssertEqual(interrupted.lastBuild?.status, .cancelled)
        XCTAssertEqual(interrupted.lastBuild?.completedEntries, 1)
        XCTAssertEqual(interrupted.lastBuild?.candidateCount, 1)
        XCTAssertEqual(interrupted.records.count, 1)
        try await updater.update()
        let calls = await extractor.calls
        XCTAssertEqual(calls, 4, "One committed entry should not be reextracted")
        let records = try await store.snapshot().records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sources.count, 3)
        // Remove one supporting entry: the remaining sources still support the fact.
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZRECENTLYDELETED=1 WHERE Z_PK=1")
        _ = try fixture.synchronize()
        try await updater.update()
        let remaining = try await store.snapshot().records
        XCTAssertEqual(remaining[0].sources.count, 2)
        XCTAssertEqual(remaining[0].state, .unreviewed)
    }

    func testUpdaterCheckpointsAndResumesWithoutDuplicateExtraction() async throws {
        let (fixture, store, _, _) = try await setup()
        let extractor = FixtureMemoryExtractor()
        let updater = PersonalMemoryUpdater(
            store: store, extractor: extractor, sourceURL: fixture.sourceURL,
            indexDirectory: fixture.indexDirectory)
        try await updater.update()
        try await updater.update()
        let calls = await extractor.calls
        XCTAssertEqual(calls, 1)
        try fixture.editBody()
        _ = try fixture.synchronize()
        try await updater.update()
        let after = await extractor.calls
        XCTAssertEqual(after, 2)
        let records = try await store.snapshot().records
        XCTAssertEqual(records.filter { $0.state != .outdated }.count, 1)
        try fixture.setDeleted(true)
        _ = try fixture.synchronize()
        try await updater.update()
        let deleted = try await store.snapshot().records
        XCTAssertTrue(deleted.allSatisfy { $0.state == .outdated })
    }
}

private actor FixtureMemoryExtractor: PersonalMemoryExtracting {
    nonisolated let processingVersion = "fixture-v1"
    var calls = 0
    func extract(from text: String) async throws -> [MemoryCandidate] {
        calls += 1
        return [
            MemoryCandidate(
                statement: text == "EDITED" ? "Changed goal" : "Initial goal", category: .goal,
                quote: text)
        ]
    }
}

private actor InterruptingExtractor: PersonalMemoryExtracting {
    nonisolated let processingVersion = "interrupting-v1"
    var calls = 0
    func extract(from text: String) async throws -> [MemoryCandidate] {
        calls += 1
        if calls == 2 { throw CancellationError() }
        return [MemoryCandidate(statement: "A durable goal", category: .goal, quote: text)]
    }
}

private struct EmptyMemoryExtractor: PersonalMemoryExtracting {
    let processingVersion = "empty-v1"
    func extract(from text: String) async throws -> [MemoryCandidate] { [] }
}
private struct InvalidMemoryExtractor: PersonalMemoryExtracting {
    let processingVersion = "invalid-v1"
    func extract(from text: String) async throws -> [MemoryCandidate] {
        [MemoryCandidate(statement: "Unsupported", category: .goal, quote: "absent from source")]
    }
}

private struct CancellingMemoryExtractor: PersonalMemoryExtracting {
    let processingVersion = "cancelling-v1"
    func extract(from text: String) async throws -> [MemoryCandidate] {
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
    }
}

// Existing store lifecycle tests deliberately give every statement equal relevance.
private struct AllRelevantMemoryEmbeddings: IdentifiedJournalTextEmbedding {
    func embeddingSpace() async throws -> EmbeddingSpace {
        EmbeddingSpace(weightsSHA256: "fixture", dimensions: 2, runtime: "fixture")
    }
    func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }
    func embedDocument(_ text: String) async throws -> [Float] { [1, 0] }
}

extension PersonalMemoryStore {
    fileprivate func fixtureProfile(sourceURL: URL = JournalReader().sourceURL) async throws
        -> PersonalMemoryProfile
    {
        try await profile(
            for: "fixture", embeddings: AllRelevantMemoryEmbeddings(), sourceURL: sourceURL)
    }
}
