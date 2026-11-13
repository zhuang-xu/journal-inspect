import Foundation
import JournalEmbeddings
import XCTest

@testable import JournalCore

final class EmbeddingCacheTests: XCTestCase {
    private func cache(_ fixture: JournalTestFixture) -> JournalEmbeddingCache {
        JournalEmbeddingCache(directory: fixture.directory.appendingPathComponent("retrieval"))
    }
    private func retriever(
        _ fixture: JournalTestFixture, _ store: JournalEmbeddingCache, _ model: CountingEmbeddings
    ) -> CachedJournalRetriever {
        CachedJournalRetriever(
            cache: store, embeddings: model,
            source: OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory))
    }
    func testNativeCachedAndTransientResultsMatch() async throws {
        guard let path = ProcessInfo.processInfo.environment["JOURNAL_EMBEDDING_MODEL"] else {
            throw XCTSkip("Set JOURNAL_EMBEDDING_MODEL for native synthetic cache equivalence.")
        }
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 2)
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTEXT='I baked chocolate cake.'; UPDATE ZJOURNALENTRYMO SET ZTEXT='我担心明天的工作面试，不知道能不能拿到这个职位。' WHERE Z_PK=1"
        )
        let model = LocalEmbeddingModel()
        do {
            try await model.load(from: URL(fileURLWithPath: path))
            let source = OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
            let store = cache(fixture)
            for question in ["What makes me anxious about work?", "What did I bake?"] {
                let request = RetrievalRequest(query: question, limit: 1)
                let cached = try await CachedJournalRetriever(
                    cache: store, embeddings: model, source: source
                ).retrieve(request)
                let transient = try await SemanticJournalRetriever(
                    embeddings: model, source: source
                ).retrieve(request)
                XCTAssertEqual(cached.map(\.id), transient.map(\.id))
                XCTAssertEqual(cached.map(\.text), transient.map(\.text))
                XCTAssertEqual(cached.map(\.date), transient.map(\.date))
            }
            let status = await store.status()
            XCTAssertEqual(status?.rebuilt, 0)
            XCTAssertEqual(status?.reused, 2)
            await model.unload()
        } catch {
            await model.unload()
            throw error
        }
    }

    func testWarmDifferentQuestionsAndRestartReuseWithoutPersistingText() async throws {
        let fixture = try JournalTestFixture()
        let model = CountingEmbeddings()
        let directory = fixture.directory.appendingPathComponent("retrieval")
        var store = JournalEmbeddingCache(directory: directory)
        let first = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "PRIVATE_QUESTION_SENTINEL"))
        XCTAssertEqual(first.map(\.text), ["PRIVATE_BODY_SENTINEL"])
        _ = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "different"))
        var counts = await model.counts()
        XCTAssertEqual(counts.documents, 1)
        XCTAssertEqual(counts.queries, 2)
        store = JournalEmbeddingCache(directory: directory)
        let again = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "restart"))
        XCTAssertEqual(again.map(\.text), first.map(\.text))
        counts = await model.counts()
        XCTAssertEqual(counts.documents, 1)
        XCTAssertEqual(counts.queries, 3)
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            let bytes = try Data(contentsOf: url)
            for sentinel in [
                "PRIVATE_BODY_SENTINEL", "PRIVATE_TITLE_SENTINEL", "PRIVATE_QUESTION_SENTINEL",
            ] {
                XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
            }
            let mode =
                try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }
    func testNewEntriesEditsMetadataOnlyDatesAndDeletion() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let search = retriever(fixture, store, model)
        _ = try await search.retrieve(RetrievalRequest(query: "work"))
        try fixture.populateEntries(count: 2)
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='interview' WHERE Z_PK=2")
        let added = try await search.retrieve(RetrievalRequest(query: "work", limit: 1))
        XCTAssertEqual(added.first?.text, "interview")
        var counts = await model.counts()
        XCTAssertEqual(counts.documents, 2)
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTITLE='new title', ZENTRYDATE=400 WHERE Z_PK=2")
        let filtered = try await search.retrieve(
            RetrievalRequest(
                query: "work", start: Date(timeIntervalSinceReferenceDate: 399),
                end: Date(timeIntervalSinceReferenceDate: 401)))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.date, Date(timeIntervalSinceReferenceDate: 400))
        counts = await model.counts()
        XCTAssertEqual(counts.documents, 2)
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTEXT='interview changed' WHERE Z_PK=2")
        let edited = try await search.retrieve(RetrievalRequest(query: "work", limit: 1))
        XCTAssertEqual(edited.first?.text, "interview changed")
        counts = await model.counts()
        XCTAssertEqual(counts.documents, 3)
        try fixture.source.execute("DELETE FROM ZJOURNALENTRYMO WHERE Z_PK=2")
        let deleted = try await search.retrieve(RetrievalRequest(query: "work"))
        XCTAssertEqual(deleted.map(\.text), ["PRIVATE_BODY_SENTINEL"])
        let status = await store.status()
        XCTAssertEqual(status?.ready, 1)
    }
    func testFractionalSourceDatesSurviveUnixStorageAndPreviewValidation() async throws {
        let fixture = try JournalTestFixture()
        let sourceDate = 812345678.1234568
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZENTRYDATE=812345678.1234568")
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let search = retriever(fixture, store, model)
        let date = Date(timeIntervalSinceReferenceDate: sourceDate)
        let first = try await search.retrieve(RetrievalRequest(query: "x"))
        XCTAssertEqual(first.map(\.date), [date])
        let refs = first.compactMap(\.reference)
        let valid = try await store.validate(refs, sourceURL: fixture.sourceURL)
        XCTAssertTrue(valid)
        let filtered = try await search.retrieve(RetrievalRequest(query: "x", start: date))
        XCTAssertEqual(filtered.count, 1)
        let excluded = try await search.retrieve(RetrievalRequest(query: "x", end: date))
        XCTAssertTrue(excluded.isEmpty)
        let counts = await model.counts()
        XCTAssertEqual(counts.documents, 1)
    }

    func testMetadataRebuildReusesBodyVectors() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
        let before = try JournalMetadataStore(directory: fixture.indexDirectory).currentReceipt()
        try FileManager.default.removeItem(at: fixture.indexDirectory)
        _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
        let after = try JournalMetadataStore(directory: fixture.indexDirectory).currentReceipt()
        XCTAssertNotEqual(before.indexInstanceID, after.indexInstanceID)
        let counts = await model.counts()
        XCTAssertEqual(counts.documents, 1)
    }
    func testEmptyThenFilledUnicodeOffsetsAndTransientEquivalence() async throws {
        let fixture = try JournalTestFixture()
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='  '")
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let empty = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "x"))
        XCTAssertTrue(empty.isEmpty)
        var counts = await model.counts()
        XCTAssertEqual(counts.documents, 0)
        let text = String(repeating: "中文😀 café\n", count: 140) + "interview"
        try Statement(fixture.source, "UPDATE ZJOURNALENTRYMO SET ZTEXT=?").execute([text])
        let request = RetrievalRequest(query: "work", limit: 1)
        let cached = try await retriever(fixture, store, model).retrieve(request)
        let transient = try await SemanticJournalRetriever(
            embeddings: model,
            source: OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        ).retrieve(request)
        XCTAssertEqual(cached.map(\.text), transient.map(\.text))
        XCTAssertEqual(cached.map(\.id), transient.map(\.id))
        counts = await model.counts()
        XCTAssertGreaterThan(counts.documents, 1)
        let reference = try XCTUnwrap(transient.first?.reference)
        let entry = try JournalReader(sourceURL: fixture.sourceURL).openEntry(
            uuid: reference.uuid, sourceID: reference.sourceID)
        let anchored = try XCTUnwrap(
            reference.excerpt(
                in: entry, currentRevision: JournalEvidenceReference.transientRevision(entry.text)))
        XCTAssertTrue(anchored.utf8.elementsEqual(try XCTUnwrap(transient.first?.text).utf8))
    }
    func testBothRetrieversExpandAcrossTheIndexedBoundaryWithExactReferences() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let text =
            "interview: I went to the attic to look for my passport. "
            + String(repeating: "Boxes lined the wall. ", count: 37)
            + "I found it there in an old map case."
        try Statement(fixture.source, "UPDATE ZJOURNALENTRYMO SET ZTEXT=?").execute([text])
        let indexed = JournalPassages.located(text)
        XCTAssertEqual(indexed.count, 2)
        XCTAssertFalse(indexed[0].text.contains("map case"))
        let request = RetrievalRequest(query: "interview", limit: 1)
        let cached = try await retriever(fixture, store, model).retrieve(request)
        let transient = try await SemanticJournalRetriever(
            embeddings: model,
            source: OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        ).retrieve(request)

        for result in [cached, transient] {
            let evidence = try XCTUnwrap(result.first)
            let reference = try XCTUnwrap(evidence.reference)
            XCTAssertTrue(evidence.text.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(reference.offset, 0)
            XCTAssertEqual(reference.length, text.utf8.count)
            let valid = try await store.validate([reference], sourceURL: fixture.sourceURL)
            XCTAssertTrue(valid)
        }
        let beforeWarm = await model.counts().documents
        _ = try await retriever(fixture, store, model).retrieve(request)
        let afterWarm = await model.counts().documents
        XCTAssertEqual(beforeWarm, afterWarm)
    }

    func testPreviewValidationRejectsEditDeletionAndReset() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let result = try await retriever(fixture, store, CountingEmbeddings()).retrieve(
            RetrievalRequest(query: "x"))
        let context = try BudgetedContextBuilder().build(from: result, tokenBudget: 4096)
        XCTAssertEqual(context.references.count, 1)
        var valid = try await store.validate(context.references, sourceURL: fixture.sourceURL)
        XCTAssertTrue(valid)
        try fixture.editBody()
        valid = try await store.validate(context.references, sourceURL: fixture.sourceURL)
        XCTAssertFalse(valid)
        try fixture.setDeleted(true)
        valid = try await store.validate(context.references, sourceURL: fixture.sourceURL)
        XCTAssertFalse(valid)
        try fixture.setDeleted(false)
        try await store.clear()
        valid = try await store.validate(context.references, sourceURL: fixture.sourceURL)
        XCTAssertFalse(valid)
    }
    func testClearDuringInferencePreventsLatePublication() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        await model.setHook { try await store.clear() }
        do {
            _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
            XCTFail("Reset accepted late inference")
        } catch JournalCacheError.staleUpdate {}
        let db = try Database(
            fixture.directory.appendingPathComponent("retrieval/embeddings.sqlite3").path,
            readOnly: true)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM passage_vectors"), "0")
        await model.setHook(nil)
        _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
    }
    func testCancellationLeavesNoSearchableDraftAndResumes() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        await model.setHook { throw CancellationError() }
        do {
            _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
            XCTFail("Cancellation ignored")
        } catch is CancellationError {}
        let db = try Database(
            fixture.directory.appendingPathComponent("retrieval/embeddings.sqlite3").path,
            readOnly: true)
        XCTAssertEqual(
            try db.scalar("SELECT count(*) FROM entry_versions WHERE complete=1 AND current=1"), "0"
        )
        await model.setHook(nil)
        let result = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "x"))
        XCTAssertEqual(result.count, 1)
    }
    func testCorruptVectorIsRebuiltAndNamespaceChangeReembeds() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let search = retriever(fixture, store, model)
        _ = try await search.retrieve(RetrievalRequest(query: "x"))
        let db = try Database(
            fixture.directory.appendingPathComponent("retrieval/embeddings.sqlite3").path,
            readOnly: false)
        try db.execute("UPDATE passage_vectors SET vector=X'00000000'")
        _ = try await search.retrieve(RetrievalRequest(query: "x"))
        var counts = await model.counts()
        XCTAssertEqual(counts.documents, 2)
        await model.changeSpace()
        _ = try await search.retrieve(RetrievalRequest(query: "x"))
        counts = await model.counts()
        XCTAssertEqual(counts.documents, 3)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM embedding_spaces"), "1")
    }
    func testWriterOwnershipAndSourceIsolation() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let other = cache(fixture)
        let model = CountingEmbeddings()
        let space = try await model.embeddingSpace()
        let ticket = try await store.begin(space: space)
        do {
            _ = try await other.begin(space: space)
            XCTFail("Second writer accepted")
        } catch JournalCacheError.busy {}
        await store.end(ticket)
        _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
        try fixture.source.execute(
            "UPDATE Z_METADATA SET Z_UUID='11112233-4455-6677-8899-aabbccddeeff'")
        let results = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "x"))
        XCTAssertEqual(results.first?.sourceID, "11112233-4455-6677-8899-aabbccddeeff")
        let counts = await model.counts()
        XCTAssertEqual(counts.documents, 2)
    }
    func testSourceEditDuringBuildRetriesAndContinuousEditsFail() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        // Worker-local writes in the callback; no source handle crosses actors.
        let sourceURL = fixture.sourceURL
        await model.setHook {
            let db = try Database(sourceURL.path, readOnly: false)
            try db.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT=ZTEXT || ' changed'")
        }
        do {
            _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
            XCTFail("Continuously edited source accepted")
        } catch JournalCacheError.sourceChanged {}
        await model.setHook(nil)
        let result = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "x"))
        XCTAssertTrue(result.first?.text.contains("changed changed") == true)
    }
    func testDeletionAfterRankingRefillsAndInvalidOffsetsRebuild() async throws {
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 2)
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTEXT='interview' WHERE Z_PK=1; UPDATE ZJOURNALENTRYMO SET ZTEXT='cake' WHERE Z_PK=2"
        )
        let store = cache(fixture)
        let model = CountingEmbeddings()
        let sourceURL = fixture.sourceURL
        let source = OnDemandJournalSource(
            sourceURL: sourceURL, indexDirectory: fixture.indexDirectory)
        let search = CachedJournalRetriever(cache: store, embeddings: model, source: source) {
            progress in
            if case .validating = progress {
                let db = try? Database(sourceURL.path, readOnly: false)
                try? db?.execute("DELETE FROM ZJOURNALENTRYMO WHERE Z_PK=1")
            }
        }
        let results = try await search.retrieve(RetrievalRequest(query: "work", limit: 1))
        XCTAssertEqual(results.map(\.text), ["cake"])
        let db = try Database(
            fixture.directory.appendingPathComponent("retrieval/embeddings.sqlite3").path,
            readOnly: false)
        try db.execute("UPDATE passage_vectors SET utf8_offset=999999")
        let repaired = try await retriever(fixture, store, model).retrieve(
            RetrievalRequest(query: "work", limit: 1))
        XCTAssertEqual(repaired.map(\.text), ["cake"])
        let counts = await model.counts()
        XCTAssertEqual(counts.documents, 3)
    }

    func testCodecRejectsBadValuesAndStoresLittleEndianFloats() throws {
        let blob = try VectorCodec.encode([1, 0], dimensions: 2)
        XCTAssertEqual(Array(blob), [0, 0, 128, 63, 0, 0, 0, 0])
        XCTAssertThrowsError(try VectorCodec.decode(Data([0]), dimensions: 2))
        for values: [Float] in [[0, 0], [.nan, 1], [.infinity, 1], [1]] {
            XCTAssertThrowsError(try VectorCodec.encode(values, dimensions: 2))
        }
    }
    func testFailedSourceSyncCannotPurgeCacheOrUseStaleEvidence() async throws {
        let fixture = try JournalTestFixture()
        let store = cache(fixture)
        let model = CountingEmbeddings()
        _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
        try fixture.source.execute("DROP TABLE ZJOURNALENTRYMO")
        do {
            _ = try await retriever(fixture, store, model).retrieve(RetrievalRequest(query: "x"))
            XCTFail("Unavailable source concealed by cache")
        } catch is JournalReaderError {}
        let db = try Database(
            fixture.directory.appendingPathComponent("retrieval/embeddings.sqlite3").path,
            readOnly: true)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM entry_versions WHERE complete=1"), "1")
    }
}

private actor CountingEmbeddings: IdentifiedJournalTextEmbedding {
    private var documents = 0
    private var queries = 0
    private var version = "test-v1"
    private var hook: (@Sendable () async throws -> Void)?
    func setHook(_ hook: (@Sendable () async throws -> Void)?) { self.hook = hook }
    func changeSpace() { version = "test-v2" }
    func embeddingSpace() throws -> EmbeddingSpace {
        EmbeddingSpace(weightsSHA256: "synthetic", dimensions: 2, runtime: version)
    }
    func embedDocument(_ text: String) async throws -> [Float] {
        documents += 1
        try await hook?()
        return text.contains("interview") ? [1, 0] : [0, 1]
    }
    func embedQuery(_ text: String) async throws -> [Float] {
        queries += 1
        return [1, 0]
    }
    func counts() -> (documents: Int, queries: Int) { (documents, queries) }
}
