import Foundation
import JournalEmbeddings
import XCTest

@testable import JournalCore

final class SemanticRetrievalTests: XCTestCase {
    func testNativeSyntheticSemanticRetrieval() async throws {
        guard let path = ProcessInfo.processInfo.environment["JOURNAL_EMBEDDING_MODEL"] else {
            throw XCTSkip(
                "Set JOURNAL_EMBEDDING_MODEL to verify synthetic native semantic retrieval.")
        }
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 2)
        try fixture.source.execute(
            """
            UPDATE ZJOURNALENTRYMO SET ZTEXT='I baked a chocolate cake for dessert.', ZENTRYDATE=100;
            UPDATE ZJOURNALENTRYMO SET ZTEXT='我担心明天的工作面试，不知道能不能拿到这个职位。',
                ZENTRYDATE=1 WHERE Z_PK=1;
            """)
        _ = try fixture.synchronize()
        let embeddings = LocalEmbeddingModel()
        do {
            try await embeddings.load(from: URL(fileURLWithPath: path))
            let prompt = try await JournalPromptAugmenter(
                retriever: retriever(fixture, embeddings: embeddings)
            ).augment("What has been making me anxious about work?")
            // Limit one in a direct search to verify the older cross-language entry wins.
            let results = try await retriever(fixture, embeddings: embeddings).retrieve(
                RetrievalRequest(query: "What has been making me anxious about work?", limit: 1))
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(results.first?.text.contains("面试") == true)
            XCTAssertTrue(prompt.context.text.contains("面试"))
            XCTAssertFalse(prompt.context.citationIDs.isEmpty)
            let bakingResults = try await retriever(fixture, embeddings: embeddings).retrieve(
                RetrievalRequest(query: "What did I bake for dessert?", limit: 1))
            XCTAssertEqual(bakingResults.count, 1)
            XCTAssertTrue(bakingResults.first?.text.contains("chocolate cake") == true)
            XCTAssertNotEqual(results.first?.id, bakingResults.first?.id)
            await embeddings.unload()
        } catch {
            await embeddings.unload()
            throw error
        }
    }

    func testTransientReferencesValidateWithoutCacheStorage() async throws {
        let fixture = try JournalTestFixture()
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='中文😀 café'")
        _ = try fixture.synchronize()
        let results = try await retriever(fixture).retrieve(RetrievalRequest(query: "x"))
        let reference = try XCTUnwrap(results.first?.reference)
        let cache = JournalEmbeddingCache(directory: fixture.sourceURL)
        func validate() async throws -> Bool {
            try await cache.validate([reference], sourceURL: fixture.sourceURL)
        }
        let valid = try await validate()
        XCTAssertTrue(valid)

        let entry = try JournalReader(sourceURL: fixture.sourceURL).openEntry(
            uuid: reference.uuid, sourceID: reference.sourceID)
        let invalid = JournalEvidenceReference(
            sourceID: reference.sourceID, uuid: reference.uuid, revision: reference.revision,
            date: reference.date, offset: 1, length: 2)
        XCTAssertNil(invalid.excerpt(in: entry, currentRevision: reference.revision))

        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZENTRYDATE=5")
        let dateChanged = try await validate()
        XCTAssertFalse(dateChanged)
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZENTRYDATE=3")
        try fixture.setDeleted(true)
        let deleted = try await validate()
        XCTAssertFalse(deleted)
        try fixture.setDeleted(false)
        try fixture.editBody()
        let edited = try await validate()
        XCTAssertFalse(edited)
    }

    func testNativeEvidenceRecallAtAssistantCandidateLimit() async throws {
        guard let path = ProcessInfo.processInfo.environment["JOURNAL_EMBEDDING_MODEL"] else {
            throw XCTSkip("Set JOURNAL_EMBEDDING_MODEL to measure synthetic evidence recall.")
        }
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 28)
        try fixture.source.execute(
            """
            UPDATE ZJOURNALENTRYMO SET ZID=CAST(printf('%016d', Z_PK) AS BLOB),
                ZENTRYDATE=Z_PK, ZTEXT='I watered the balcony plants.';
            UPDATE ZJOURNALENTRYMO SET ZTEXT='I felt nervous about the interview.' WHERE Z_PK=1;
            UPDATE ZJOURNALENTRYMO SET ZTEXT='复试前我并不担心，睡得很好。' WHERE Z_PK=2;
            UPDATE ZJOURNALENTRYMO SET ZTEXT='I bought clothes for the interview.' WHERE Z_PK=3;
            UPDATE ZJOURNALENTRYMO SET ZTEXT='周二晚餐我吃了番茄鸡蛋面。' WHERE Z_PK=4;
            """)
        let cases: [(label: String, question: String, expected: Set<Int>)] = [
            (
                "interview-comparison", "How did my anxiety differ before my two interviews?",
                [1, 2]
            ),
            ("dinner-lookup", "周二晚餐我吃了什么？", [4]),
            ("missing-evidence", "What was the result of my job interview?", []),
        ]
        let model = LocalEmbeddingModel()
        try await model.load(from: URL(fileURLWithPath: path))
        do {
            let retriever = CachedJournalRetriever(
                cache: JournalEmbeddingCache(
                    directory: fixture.directory.appendingPathComponent("cache")),
                embeddings: model,
                source: OnDemandJournalSource(
                    sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory))
            for item in cases {
                let candidates = try await retriever.retrieve(
                    JournalQueryPlanner.request(for: item.question))
                let context = try BudgetedContextBuilder().build(
                    from: candidates, tokenBudget: 4096)
                let retained = Set(context.citationIDs)
                func dates(_ entries: [JournalEvidence]) -> Set<Int> {
                    Set(
                        entries.compactMap {
                            $0.date.map { Int($0.timeIntervalSinceReferenceDate) }
                        })
                }
                let candidateHits = dates(candidates).intersection(item.expected).count
                let contextHits = dates(candidates.filter { retained.contains($0.id) })
                    .intersection(item.expected).count
                print(
                    "Synthetic evidence v1 \(item.label): candidates \(candidateHits)/\(item.expected.count); context \(contextHits)/\(item.expected.count); context size \(retained.count)"
                )
                XCTAssertEqual(candidates.count, 25)
                XCTAssertEqual(candidateHits, item.expected.count)
                XCTAssertEqual(contextHits, item.expected.count)
            }
            await model.unload()
        } catch {
            await model.unload()
            throw error
        }
    }

    func testFindsOldEntryBeyondFirstPageAndReadsCurrentText() async throws {
        let fixture = try JournalTestFixture()
        try fixture.populateEntries(count: 53)
        try fixture.source.execute(
            """
            UPDATE ZJOURNALENTRYMO SET ZTEXT='cake', ZENTRYDATE=100;
            UPDATE ZJOURNALENTRYMO SET ZTEXT='old text', ZENTRYDATE=1 WHERE Z_PK=1;
            """)
        _ = try fixture.synchronize()
        try fixture.source.execute(
            "UPDATE ZJOURNALENTRYMO SET ZTEXT='interview anxiety' WHERE Z_PK=1")
        let result = try await retriever(fixture).retrieve(
            RetrievalRequest(query: "work worry", limit: 1))
        XCTAssertEqual(result.map(\.text), ["interview anxiety"])
        XCTAssertEqual(result.first?.date, Date(timeIntervalSinceReferenceDate: 1))
        // Date filters still apply before scoring.
        let filtered = try await retriever(fixture).retrieve(
            RetrievalRequest(
                query: "work worry", start: Date(timeIntervalSinceReferenceDate: 2), limit: 1))
        XCTAssertEqual(filtered.map(\.text), ["cake"])
        try fixture.setDeleted(true)
        let deleted = try await retriever(fixture).retrieve(RetrievalRequest(query: "work worry"))
        XCTAssertTrue(deleted.isEmpty)
        for url in try FileManager.default.contentsOfDirectory(
            at: fixture.indexDirectory, includingPropertiesForKeys: nil)
        {
            XCTAssertNil(try Data(contentsOf: url).range(of: Data("interview anxiety".utf8)))
        }
    }

    func testLongEntryReturnsRelevantExcerptWithOriginalCitation() async throws {
        let fixture = try JournalTestFixture()
        let text = String(repeating: "cake ", count: 1000) + "interview anxiety"
        let update = try Statement(fixture.source, "UPDATE ZJOURNALENTRYMO SET ZTEXT=?")
        try update.execute([text])
        _ = try fixture.synchronize()
        let prompt = try await JournalPromptAugmenter(retriever: retriever(fixture))
            .augment("work worry")
        XCTAssertEqual(prompt.context.citationIDs.count, 1)
        XCTAssertTrue(prompt.context.text.contains("interview anxiety"))
        XCTAssertLessThan(prompt.context.text.utf8.count, 1500)
        XCTAssertTrue(prompt.instructions.contains("excerpts"))
    }

    func testUnicodeChunkingPreservesAllTextAndBoundsInputs() {
        let text = String(repeating: "中文😀 café\n", count: 1000)
        let passages = JournalPassages.located(text).map(\.text)
        XCTAssertGreaterThan(passages.count, 1)
        XCTAssertEqual(passages.joined(), text)
        XCTAssertTrue(passages.allSatisfy { $0.utf8.count <= JournalPassages.maximumBytes })
        XCTAssertTrue(JournalPassages.located(" \n\t").isEmpty)
    }

    func testExpansionPreservesExactUnicodeBytesWithoutSentenceBoundaries() throws {
        let original = String(repeating: "中文😀é", count: 500)
        let passages = JournalPassages.located(original)
        for anchor in [try XCTUnwrap(passages.first), passages[2], try XCTUnwrap(passages.last)] {
            let excerpt = JournalPassages.expanded(anchor, in: original)
            XCTAssertLessThanOrEqual(excerpt.length, JournalPassages.maximumExcerptBytes)
            XCTAssertLessThanOrEqual(excerpt.offset, anchor.offset)
            XCTAssertGreaterThanOrEqual(
                excerpt.offset + excerpt.length, anchor.offset + anchor.length)
            let exactBytes = original.utf8.dropFirst(excerpt.offset).prefix(excerpt.length)
            XCTAssertTrue(excerpt.text.utf8.elementsEqual(exactBytes))
        }
    }

    func testInvalidVectorsEmptyQueryLimitAndCancellation() async throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        for vector: [Float] in [[], [0, 0], [.nan, 1], [.infinity, 1], [1]] {
            do {
                _ = try await retriever(fixture, embeddings: InvalidEmbeddings(vector: vector))
                    .retrieve(RetrievalRequest(query: "x"))
                XCTFail("Invalid or mismatched vector accepted")
            } catch SemanticRetrievalError.invalidVector {}
        }
        do {
            _ = try await retriever(fixture).retrieve(RetrievalRequest(query: " \n"))
            XCTFail("Empty query accepted")
        } catch SemanticRetrievalError.emptyQuery {}
        do {
            _ = try await retriever(fixture).retrieve(RetrievalRequest(query: "x", limit: 51))
            XCTFail("Invalid limit accepted")
        } catch AugmentationError.invalidLimit {}
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await retriever(fixture).retrieve(RetrievalRequest(query: "x"))
        }
        do {
            _ = try await job.value
            XCTFail("Cancellation ignored")
        } catch is CancellationError {}
    }

    func testCancellationDuringEmbeddingStopsSearch() async throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        do {
            _ = try await retriever(fixture, embeddings: CancellingEmbeddings())
                .retrieve(RetrievalRequest(query: "x"))
            XCTFail("Embedding cancellation swallowed")
        } catch is CancellationError {}
    }

    func testCurrentTextFlowsToPromptWithoutPersistingIt() async throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        try fixture.source.execute("UPDATE ZJOURNALENTRYMO SET ZTEXT='CURRENT_PRIVATE_TEXT'")
        let augmenter = JournalPromptAugmenter(retriever: retriever(fixture))
        let result = try await augmenter.augment("Reflect on today")
        XCTAssertEqual(result.userPrompt, "Reflect on today")
        XCTAssertTrue(result.context.text.contains("CURRENT_PRIVATE_TEXT"))
        XCTAssertFalse(result.context.text.contains("PRIVATE_BODY_SENTINEL"))
        XCTAssertEqual(result.context.citationIDs.count, 1)
        XCTAssertFalse(String(reflecting: result).contains("CURRENT_PRIVATE_TEXT"))
        for file in try FileManager.default.contentsOfDirectory(
            at: fixture.indexDirectory, includingPropertiesForKeys: nil)
        {
            let data = try Data(contentsOf: file)
            for sentinel in [
                "CURRENT_PRIVATE_TEXT", "PRIVATE_BODY_SENTINEL", "PRIVATE_TITLE_SENTINEL",
            ] {
                XCTAssertNil(data.range(of: Data(sentinel.utf8)))
            }
        }
        try fixture.setDeleted(true)
        let deleted = try await augmenter.augment("Reflect")
        XCTAssertEqual(deleted.context.citationIDs, [])
    }

    func testDateWindowUsesInclusiveStartAndExclusiveEnd() async throws {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let retriever = retriever(fixture)
        let inside = try await retriever.retrieve(
            RetrievalRequest(
                query: "x",
                start: Date(timeIntervalSinceReferenceDate: 3),
                end: Date(timeIntervalSinceReferenceDate: 4)))
        XCTAssertEqual(inside.count, 1)
        let outside = try await retriever.retrieve(
            RetrievalRequest(
                query: "x",
                end: Date(timeIntervalSinceReferenceDate: 3)))
        XCTAssertTrue(outside.isEmpty)
    }

    private func retriever(
        _ fixture: JournalTestFixture, embeddings: any JournalTextEmbedding = FixtureEmbeddings()
    ) -> SemanticJournalRetriever {
        SemanticJournalRetriever(
            embeddings: embeddings,
            source: OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory))
    }
}

private struct FixtureEmbeddings: JournalTextEmbedding {
    func embedQuery(_ text: String) async throws -> [Float] { [2, 0] }

    func embedDocument(_ text: String) async throws -> [Float] {
        text.contains("interview") ? [3, 0] : [0, 1]
    }
}

private struct InvalidEmbeddings: JournalTextEmbedding {
    let vector: [Float]

    func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }

    func embedDocument(_ text: String) async throws -> [Float] { vector }
}

private struct CancellingEmbeddings: JournalTextEmbedding {
    func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }

    func embedDocument(_ text: String) async throws -> [Float] { throw CancellationError() }
}
