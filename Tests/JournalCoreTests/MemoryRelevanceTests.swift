import Foundation
import JournalEmbeddings
import XCTest

@testable import JournalCore

final class MemoryRelevanceTests: XCTestCase {
    private func store(_ fixture: JournalTestFixture, cache: JournalEmbeddingCache? = nil)
        async throws
        -> PersonalMemoryStore
    {
        let store = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"), embeddingCache: cache)
        try await store.setEnabled(true)
        return store
    }
    private func save(_ text: String, to store: PersonalMemoryStore) async throws {
        try await store.save(
            statement: text, category: .circumstance, asOf: Date(timeIntervalSince1970: 10))
    }
    private func statements(_ profile: PersonalMemoryProfile) throws -> [String] {
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(profile.text.utf8)) as? [[String: Any]])
        return try rows.map { try XCTUnwrap($0["statement"] as? String) }
    }
    private func profile(
        _ store: PersonalMemoryStore, _ fixture: JournalTestFixture,
        _ model: MemoryTestEmbeddings, cached: Bool = true
    ) async throws -> PersonalMemoryProfile {
        try await store.profile(
            for: "question", embeddings: model, reuseCachedVectors: cached,
            sourceURL: fixture.sourceURL)
    }
    private func vectorCount(_ fixture: JournalTestFixture) throws -> Int {
        let db = try Database(
            fixture.directory.appendingPathComponent("vectors").appendingPathComponent(
                "embeddings.sqlite3"
            ).path, readOnly: true)
        return Int(try db.scalar("SELECT count(*) FROM memory_vectors"))!
    }

    func testRelevantUnreviewedBeatsUnrelatedConfirmedAndKeepsReviewMetadata() async throws {
        let fixture = try JournalTestFixture()
        let store = try await store(fixture)
        let body = "Sunday calls with my father.\nI prefer tea."
        try Statement(fixture.source, "UPDATE ZJOURNALENTRYMO SET ZTEXT=?").execute([body])
        _ = try fixture.synchronize()
        let entries = try JournalMetadataStore(directory: fixture.indexDirectory).browse().entries
        let generation = try await store.beginUpdate(entries: entries)
        try await store.replace(
            entry: entries[0], text: body,
            candidates: [
                MemoryCandidate(
                    statement: "Father", category: .relationship, quote: "Sunday calls"),
                MemoryCandidate(statement: "Tea", category: .preference, quote: "prefer tea"),
            ], version: "fixture", generation: generation)
        let tea = try await store.snapshot().records.first { $0.statement == "Tea" }!
        try await store.approve(tea.id)
        let result = try await profile(
            store, fixture, MemoryTestEmbeddings(vectors: ["Father": [1, 0]]))
        XCTAssertEqual(try statements(result), ["Father"])
        XCTAssertTrue(result.text.contains("automatic_unconfirmed"))
        XCTAssertEqual(result.omittedCount, 1)
        let revision = try await store.selectionRevision()
        try fixture.editBody()
        let valid = try await store.validateProfile(
            result, revision: revision, sourceURL: fixture.sourceURL)
        XCTAssertFalse(valid, "Selected automatic support changed without a memory-store edit")
    }

    func testGenerateValidationRejectsStoreChangesAfterRanking() async throws {
        let fixture = try JournalTestFixture()
        let store = try await store(fixture)
        try await save("First", to: store)
        let revision = try await store.selectionRevision()
        let selected = try await profile(
            store, fixture, MemoryTestEmbeddings(defaultVector: [1, 0]))
        let valid = try await store.validateProfile(
            selected, revision: revision, sourceURL: fixture.sourceURL)
        XCTAssertTrue(valid)
        try await store.setEnabled(false)
        let stale = try await store.validateProfile(
            selected, revision: revision, sourceURL: fixture.sourceURL)
        XCTAssertFalse(stale)
    }

    func testEmptyDisabledAndAllIrrelevantCanReturnNoMemory() async throws {
        let fixture = try JournalTestFixture()
        let store = try await store(fixture)
        let model = MemoryTestEmbeddings()
        let empty = try await profile(store, fixture, model)
        XCTAssertEqual(empty.text, "[]")
        try await save("Unrelated", to: store)
        let unrelated = try await profile(store, fixture, model)
        XCTAssertEqual(unrelated.text, "[]")
        XCTAssertEqual(unrelated.omittedCount, 1)
        try await store.setEnabled(false)
        let before = await model.queries
        let disabled = try await profile(store, fixture, model)
        let after = await model.queries
        XCTAssertEqual(disabled.text, "[]")
        XCTAssertEqual(before, after)
    }

    func testDeduplicatesExactNormalizedStatementsButPreservesNegationAndConflict() async throws {
        let fixture = try JournalTestFixture()
        let store = try await store(fixture)
        for text in ["I like coffee", "I  LIKE coffee", "I do not like coffee"] {
            try await save(text, to: store)
        }
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        let result = try await profile(store, fixture, model)
        XCTAssertEqual(try statements(result).count, 2)
        XCTAssertTrue(try statements(result).contains("I do not like coffee"))
        XCTAssertEqual(result.omittedCount, 1)
    }

    func testWarmReopenReusesVectorsAndEditReembedsOnlyChangedStatement() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        try await save("First", to: store)
        try await save("Second", to: store)
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        _ = try await profile(store, fixture, model)
        let warm = PersonalMemoryStore(
            directory: fixture.directory.appendingPathComponent("memory"),
            embeddingCache: JournalEmbeddingCache(
                directory: fixture.directory.appendingPathComponent("vectors")))
        _ = try await profile(warm, fixture, model)
        let initialCalls = await model.documents
        XCTAssertEqual(initialCalls, 2)
        let id = try await store.snapshot().records.first { $0.statement == "First" }!.id
        try await store.save(id: id, statement: "Changed", category: .goal, asOf: Date())
        XCTAssertEqual(try vectorCount(fixture), 1)
        _ = try await profile(store, fixture, model)
        let updatedCalls = await model.documents
        XCTAssertEqual(updatedCalls, 3)
        XCTAssertEqual(try vectorCount(fixture), 2)
        let data = try Data(
            contentsOf: fixture.directory.appendingPathComponent("vectors").appendingPathComponent(
                "embeddings.sqlite3"))
        XCTAssertNil(data.range(of: Data("Changed".utf8)))
    }

    func testForgetDisableAndDeleteAllRemoveVectorsImmediately() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        try await save("First", to: store)
        try await save("Second", to: store)
        _ = try await profile(store, fixture, model)
        let id = try await store.snapshot().records[0].id
        try await store.forget(id)
        XCTAssertEqual(try vectorCount(fixture), 1)
        try await store.setEnabled(false)
        XCTAssertEqual(try vectorCount(fixture), 0)
        try await store.setEnabled(true)
        _ = try await profile(store, fixture, model)
        XCTAssertEqual(try vectorCount(fixture), 1)
        try await store.deleteAll()
        XCTAssertEqual(try vectorCount(fixture), 0)
    }

    func testTransientModeDoesNotPersistAndModelSpaceChangesInvalidateVectors() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        try await save("First", to: store)
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        _ = try await profile(store, fixture, model, cached: false)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent("vectors").appendingPathComponent(
                    "embeddings.sqlite3"
                ).path))
        _ = try await profile(store, fixture, model)
        let changed = MemoryTestEmbeddings(defaultVector: [1, 0], identity: "changed")
        _ = try await profile(store, fixture, changed)
        let calls = await changed.documents
        XCTAssertEqual(calls, 1)
    }

    func testForgetDuringInferenceCannotRepublishStaleVectors() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        try await save("First", to: store)
        let id = try await store.snapshot().records[0].id
        let model = MemoryTestEmbeddings(
            defaultVector: [1, 0], duringDocument: { try await store.forget(id) })
        do {
            _ = try await profile(store, fixture, model)
            XCTFail("Stale inference was published")
        } catch JournalCacheError.staleUpdate {}
        XCTAssertEqual(try vectorCount(fixture), 0)
        // The cache writer is released even on failure.
        _ = try await profile(store, fixture, MemoryTestEmbeddings())
    }

    func testInvalidDimensionsAndCancellationReleaseCacheWriter() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        try await save("First", to: store)
        do {
            _ = try await profile(store, fixture, MemoryTestEmbeddings(defaultVector: [1]))
            XCTFail("Invalid dimensions accepted")
        } catch SemanticRetrievalError.invalidVector {}
        do {
            _ = try await profile(
                store, fixture, MemoryTestEmbeddings(duringDocument: { throw CancellationError() }))
            XCTFail("Cancellation ignored")
        } catch is CancellationError {}
        _ = try await profile(store, fixture, MemoryTestEmbeddings(defaultVector: [1, 0]))
    }

    func testCorruptMemoryVectorIsRebuiltWithoutDiscardingOtherVectors() async throws {
        let fixture = try JournalTestFixture()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: cache)
        try await save("First", to: store)
        try await save("Second", to: store)
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        _ = try await profile(store, fixture, model)
        let db = try Database(
            fixture.directory.appendingPathComponent("vectors/embeddings.sqlite3").path,
            readOnly: false)
        try db.execute(
            "UPDATE memory_vectors SET vector=X'00' WHERE memory_id=(SELECT memory_id FROM memory_vectors LIMIT 1)"
        )
        _ = try await profile(store, fixture, model)
        let calls = await model.documents
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(try vectorCount(fixture), 2)
    }

    func testTransientSelectionRejectsConcurrentStoreEdits() async throws {
        let fixture = try JournalTestFixture()
        let store = try await store(fixture)
        try await save("First", to: store)
        let model = MemoryTestEmbeddings(
            defaultVector: [1, 0],
            duringDocument: {
                try await store.save(statement: "New correction", category: .goal, asOf: Date())
            })
        do {
            _ = try await profile(store, fixture, model)
            XCTFail("Concurrent mutation was ignored")
        } catch PersonalMemoryError.staleUpdate {}
    }

    func testVersionOneMigrationPreservesExistingDocumentVectorsAndClearResetsBothNamespaces()
        async throws
    {
        let fixture = try JournalTestFixture()
        _ = try fixture.synchronize()
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let model = MemoryTestEmbeddings(defaultVector: [1, 0])
        _ = try await JournalEmbeddingCacheUpdater(
            cache: cache, embeddings: model,
            source: OnDemandJournalSource(
                sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        ).update()
        let db = try Database(
            fixture.directory.appendingPathComponent("vectors").appendingPathComponent(
                "embeddings.sqlite3"
            ).path, readOnly: false)
        let before = try db.scalar("SELECT hex(vector) FROM passage_vectors LIMIT 1")
        try db.execute("DROP TABLE memory_vectors; DROP TABLE memory_epochs; PRAGMA user_version=1")
        let reopened = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("vectors"))
        let store = try await store(fixture, cache: reopened)
        try await save("Memory", to: store)
        _ = try await profile(store, fixture, model)
        XCTAssertEqual(try db.scalar("PRAGMA user_version"), "2")
        XCTAssertEqual(try db.scalar("SELECT hex(vector) FROM passage_vectors LIMIT 1"), before)
        XCTAssertEqual(try vectorCount(fixture), 1)
        try await reopened.clear()
        XCTAssertEqual(try vectorCount(fixture), 0)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM passage_vectors"), "0")
    }
}

private actor MemoryTestEmbeddings: IdentifiedJournalTextEmbedding {
    let vectors: [String: [Float]]
    let defaultVector: [Float]
    let identity: String
    let duringDocument: (@Sendable () async throws -> Void)?
    var documents = 0
    var queries = 0
    init(
        vectors: [String: [Float]] = [:], defaultVector: [Float] = [0, 1],
        identity: String = "fixture",
        duringDocument: (@Sendable () async throws -> Void)? = nil
    ) {
        self.vectors = vectors
        self.defaultVector = defaultVector
        self.identity = identity
        self.duringDocument = duringDocument
    }
    func embeddingSpace() async throws -> EmbeddingSpace {
        EmbeddingSpace(weightsSHA256: identity, dimensions: 2, runtime: "fixture")
    }
    func embedQuery(_ text: String) async throws -> [Float] {
        queries += 1
        return [1, 0]
    }
    func embedDocument(_ text: String) async throws -> [Float] {
        documents += 1
        try await duringDocument?()
        return vectors[text] ?? defaultVector
    }
}

final class MemoryRelevanceNativeTests: XCTestCase {
    // Development fixtures only. Freeze a separate holdout before any release-quality claim.
    func testPinnedModelSelectionOnBilingualDevelopmentCases() async throws {
        guard let path = ProcessInfo.processInfo.environment["JOURNAL_EMBEDDING_MODEL"] else {
            throw XCTSkip("Set JOURNAL_EMBEDDING_MODEL for native memory selection.")
        }
        let cases: [(String, [String], Set<Int>)] = [
            (
                "What changed in my relationship with my father?",
                ["I prefer green tea.", "My father and I now talk every Sunday."], [1]
            ),
            ("我和父亲的关系最近有什么变化？", ["我喜欢喝绿茶。", "我和父亲从这个月开始每周日通电话。"], [1]),
            ("How do I prefer to receive feedback?", ["我住在杭州。", "我更喜欢书面反馈，因为这样有时间思考。"], [1]),
            (
                "What did I eat on Tuesday?",
                ["I prefer green tea.", "My father and I talk every Sunday."], []
            ),
            ("周二午餐吃了什么？", ["我正在准备后端开发面试。"], []),
            (
                "Do I enjoy telephone calls?",
                [
                    "I do not enjoy telephone calls; I prefer written messages.",
                    "I prefer green tea.",
                ], [0]
            ),
            (
                "How has my coffee preference changed?",
                [
                    "In January I preferred coffee to tea.",
                    "Since October I avoid coffee and prefer tea.",
                ], [0, 1]
            ),
            ("What city do I live in?", ["I live in Hangzhou.", "I prefer green tea."], [0]),
            (
                "What career goal am I working toward?",
                [
                    "I am preparing for backend engineering interviews.",
                    "I prefer cycling to driving.",
                ], [0]
            ),
            ("我最近在为哪个职业目标做准备？", ["我正在准备后端开发面试。", "我喜欢喝绿茶。"], [0]),
            (
                "What kind of communication works best for me?",
                [
                    "I prefer written messages because I need time to organize my thoughts.",
                    "My father lives in Shanghai.",
                ], [0]
            ),
            ("我喜欢什么样的反馈方式？", ["我更喜欢书面反馈，因为这样有时间思考。", "我每周日和父亲通电话。"], [0]),
            (
                "What helps me manage work stress?",
                ["Walking after work helps me manage stress.", "I live in Hangzhou."], [0]
            ),
            ("什么能帮助我缓解工作压力？", ["下班后散步能帮助我缓解工作压力。", "我更喜欢书面反馈。"], [0]),
            (
                "Where did I leave my keys yesterday?",
                ["I am preparing for interviews.", "My partner is named Alex."], []
            ),
            ("昨天把钥匙放在哪里了？", ["我喜欢喝绿茶。", "我住在杭州。"], []),
            (
                "When is my next dentist appointment?",
                ["My father and I talk every Sunday.", "I prefer written feedback."], []
            ),
            ("下次看牙医的预约是什么时候？", ["我和父亲每周日通电话。", "我正在准备面试。"], []),
            (
                "How do I feel about coffee now?",
                [
                    "I no longer drink coffee because it keeps me awake.",
                    "I used to enjoy morning coffee.", "I prefer written feedback.",
                ], [0, 1]
            ),
            ("我现在还喜欢喝咖啡吗？", ["以前我喜欢喝咖啡。", "从十月起我不再喝咖啡，改喝茶了。", "我住在杭州。"], [0, 1]),
        ]
        let model = LocalEmbeddingModel()
        do {
            try await model.load(from: URL(fileURLWithPath: path))
            var observations: [[String: Any]] = []
            var hits = 0
            var expected = 0
            var irrelevant = 0
            var included = 0
            for (index, test) in cases.enumerated() {
                let fixture = try JournalTestFixture()
                let store = PersonalMemoryStore(
                    directory: fixture.directory.appendingPathComponent("memory"))
                try await store.setEnabled(true)
                for statement in test.1 {
                    try await store.save(
                        statement: statement, category: .circumstance,
                        asOf: Date(timeIntervalSince1970: 1))
                }
                let selected = try await store.profile(
                    for: test.0, embeddings: model, sourceURL: fixture.sourceURL)
                let rows = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(selected.text.utf8)) as? [[String: Any]]
                )
                let selectedIndices = Set(
                    rows.compactMap { row in
                        test.1.firstIndex(of: row["statement"] as? String ?? "")
                    })
                hits += selectedIndices.intersection(test.2).count
                expected += test.2.count
                irrelevant += selectedIndices.subtracting(test.2).count
                included += selectedIndices.count
                let query = try EmbeddingVector.normalized(try await model.embedQuery(test.0))
                var scores: [Double] = []
                for statement in test.1 {
                    let vector = try EmbeddingVector.normalized(
                        try await model.embedDocument(statement))
                    scores.append(zip(query, vector).reduce(0) { $0 + $1.0 * $1.1 })
                }
                observations.append([
                    "case": index, "scores": scores, "expected": test.2.sorted(),
                    "selected": selectedIndices.sorted(),
                ])
                if test.2.isEmpty {
                    XCTAssertTrue(selectedIndices.isEmpty, "Negative native case \(index)")
                }
            }
            // This fixed development operating point deliberately favors precision. Two broad
            // career-goal phrasings remain known misses; do not relabel them as irrelevant.
            XCTAssertGreaterThanOrEqual(hits, 15)
            XCTAssertEqual(expected, 17)
            XCTAssertEqual(irrelevant, 0)
            if let report = ProcessInfo.processInfo.environment["JOURNAL_MEMORY_EVALUATION_REPORT"]
            {
                let data = try JSONSerialization.data(
                    withJSONObject: [
                        "development_cases": cases.count, "relevant_selected": hits,
                        "relevant_total": expected,
                        "irrelevant_selected": irrelevant, "selected_total": included,
                        "minimum_similarity": PersonalMemorySelection.minimumSimilarity,
                        "model_sha256": LocalEmbeddingModel.modelSHA256,
                        "cases": observations,
                    ], options: [.sortedKeys, .prettyPrinted])
                try data.write(to: URL(fileURLWithPath: report))
            }
            await model.unload()
        } catch {
            await model.unload()
            throw error
        }
    }
}
