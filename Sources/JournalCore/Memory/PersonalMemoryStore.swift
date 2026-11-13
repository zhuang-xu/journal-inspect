import Foundation

/// Sensitive derived content lives in its own private database, never in the metadata index.
/// Actor isolation and a single SQLite transaction protect edits, checkpoints and suppressions.
public actor PersonalMemoryStore {
    private struct State: Codable {
        var enabled = false
        var records: [PersonalMemory] = []
        var processed: [String: String] = [:]
        var suppressed: [String: Set<String>] = [:]
        var generation = UUID()
        var lastBuild: MemoryBuildReport?
        var backgroundPolicyVersion: Int? = 1
    }
    private let directory: URL
    private let embeddingCache: JournalEmbeddingCache?
    private var vectorNamespace: String { memoryRevision(directory.standardizedFileURL.path) }
    public init(
        directory: URL = JournalMetadataStore.defaultDirectory.appendingPathComponent("Memory"),
        embeddingCache: JournalEmbeddingCache? = nil
    ) {
        self.directory = directory
        self.embeddingCache = embeddingCache
    }

    private func database() throws -> Database {
        let url = try PrivateStoreFile.prepare(in: directory, named: "personal-memory.sqlite3")
        let db = try Database(url.path, readOnly: false)
        let appID = try db.scalar("PRAGMA application_id")
        let tables = try db.scalar("SELECT count(*) FROM sqlite_master WHERE type='table'")
        try require(
            (appID == "0" && tables == "0") || appID == "1246645300",
            "Invalid memory database.")
        try require(
            try db.scalar("PRAGMA user_version") == "0" || db.scalar("PRAGMA user_version") == "1",
            "Unsupported memory database version.")
        try db.execute(
            "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY"
        )
        try db.execute(
            "PRAGMA application_id=1246645300; PRAGMA user_version=1; CREATE TABLE IF NOT EXISTS memory_state(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)"
        )
        return db
    }
    private func read(_ db: Database) throws -> State {
        let query = try Statement(db, "SELECT value FROM memory_state WHERE id=1")
        guard try query.next(), let text = query.text(0) else { return State() }
        var state = try JSONDecoder().decode(State.self, from: Data(text.utf8))
        if state.backgroundPolicyVersion == nil {
            // Earlier builds used awaitingClarification for every unreviewed proposal.
            // Migrate that queue to automatic background without claiming user confirmation.
            for i in state.records.indices
            where state.records[i].origin == .automatic
                && state.records[i].state == .awaitingClarification
            {
                state.records[i].state = .unreviewed
            }
            state.backgroundPolicyVersion = 1
        }
        return state
    }
    private func change<T: Sendable>(
        checkCancellation: Bool = true, _ body: (inout State) throws -> T
    ) async throws
        -> T
    {
        let db = try database()
        let (result, invalidated, reset) = try db.transaction {
            var state = try read(db)
            let previous = state
            let result = try body(&state)
            if checkCancellation { try Task.checkCancellation() }
            let data = try JSONEncoder().encode(state)
            try Statement(db, "INSERT OR REPLACE INTO memory_state VALUES(1,?)")
                .execute([String(decoding: data, as: UTF8.self)])
            let current = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id, $0) })
            let invalidated = previous.records.filter { old in
                guard let record = current[old.id] else { return true }
                return record.statement != old.statement
                    || (record.state != .active && record.state != .unreviewed)
            }.map(\.id)
            return (result, invalidated, !state.enabled)
        }
        // Invalidate the vector namespace epoch too: in-flight inference cannot republish
        // an edited/forgotten statement after this operation returns.
        if let embeddingCache, reset || !invalidated.isEmpty {
            try await embeddingCache.invalidateMemories(
                namespace: vectorNamespace, ids: reset ? nil : invalidated)
        }
        return result
    }
    public func snapshot() throws -> MemorySnapshot {
        let state = try read(database())
        return MemorySnapshot(
            enabled: state.enabled, records: state.records,
            processedEntryCount: state.processed.count, lastBuild: state.lastBuild)
    }
    func recordBuild(_ report: MemoryBuildReport, generation: UUID) async throws {
        // Cancellation may save aggregate status, never a partially extracted fact.
        try await change(checkCancellation: false) { state in
            guard state.generation == generation else { throw PersonalMemoryError.staleUpdate }
            state.lastBuild = report
        }
    }
    public func setEnabled(_ enabled: Bool) async throws {
        try await change {
            $0.enabled = enabled
            $0.generation = UUID()
        }
    }
    public func save(id: UUID? = nil, statement: String, category: MemoryCategory, asOf: Date)
        async throws
    {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 600 else {
            throw PersonalMemoryError.invalidCandidate
        }
        try await change { state in
            if let id, let i = state.records.firstIndex(where: { $0.id == id }) {
                state.records[i].statement = text
                state.records[i].category = category
                state.records[i].asOf = asOf
                state.records[i].origin = .user
                state.records[i].processingVersion = "user-v1"
                state.records[i].state = .active
            } else {
                state.records.append(
                    PersonalMemory(
                        id: UUID(), statement: text, category: category,
                        asOf: asOf, sources: [], origin: .user, state: .active,
                        processingVersion: "user-v1"))
            }
            state.generation = UUID()
        }
    }
    public func approve(_ id: UUID) async throws {
        try await change { state in
            if let i = state.records.firstIndex(where: { $0.id == id }),
                !state.records[i].sources.isEmpty
            {
                state.records[i].state = .active
            }
            state.generation = UUID()
        }
    }
    public func markOutdated(_ id: UUID) async throws {
        try await change { state in
            if let i = state.records.firstIndex(where: { $0.id == id }) {
                state.records[i].state = .outdated
                state.records[i].origin = .user
                state.records[i].processingVersion = "user-v1"
            }
            state.generation = UUID()
        }
    }
    public func forget(_ id: UUID) async throws {
        try await change { state in
            guard let record = state.records.first(where: { $0.id == id }) else { return }
            for source in record.sources {
                state.suppressed[source.entryID + ":" + source.textRevision, default: []]
                    .insert(
                        record.origin == .user ? "*" : memoryRevision(memoryKey(record.statement)))
            }
            state.records.removeAll { $0.id == id }
            state.generation = UUID()
        }
    }
    public func deleteAll() async throws {
        try await change { state in
            state = State()
        }
    }
    public func restoreSuggestions() async throws {
        try await change {
            $0.suppressed = [:]
            $0.processed = [:]
            $0.generation = UUID()
        }
    }
    func beginUpdate(entries: [JournalEntry]) async throws -> UUID {
        try await change { state in
            guard state.enabled else { throw PersonalMemoryError.disabled }
            let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fingerprint) })
            for i in state.records.indices where state.records[i].origin == .automatic {
                state.records[i].sources.removeAll { current[$0.entryID] != $0.fingerprint }
                if !state.records[i].sources.isEmpty {
                    state.records[i].asOf = state.records[i].sources.compactMap(\.date).max()
                }
                if state.records[i].origin == .automatic, state.records[i].sources.isEmpty {
                    state.records[i].state = .outdated
                }
            }
            state.processed = state.processed.filter { current[$0.key] != nil }
            return state.generation
        }
    }
    func needsUpdate(entry: JournalEntry, revision: String, version: String) throws -> Bool {
        try read(database()).processed[entry.id] != entry.fingerprint + ":" + revision + ":"
            + version
    }
    func replace(
        entry: JournalEntry, text: String, candidates: [MemoryCandidate],
        version: String, generation: UUID
    ) async throws {
        guard candidates.count <= 12 else { throw PersonalMemoryError.invalidCandidate }
        let revision = memoryRevision(text)
        var validated: [(MemoryCandidate, MemorySource)] = []
        for candidate in candidates {
            let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty, statement.utf8.count <= 600,
                !candidate.quote.isEmpty, candidate.quote.utf8.count <= 1500,
                let range = text.range(of: candidate.quote, options: .literal)
            else { throw PersonalMemoryError.invalidCandidate }
            validated.append(
                (
                    MemoryCandidate(
                        statement: statement, category: candidate.category, quote: candidate.quote),
                    MemorySource(
                        sourceID: entry.sourceID, uuid: entry.uuid,
                        fingerprint: entry.fingerprint, textRevision: revision,
                        date: (entry.entryDate ?? entry.created).map(
                            Date.init(timeIntervalSinceReferenceDate:)),
                        utf8Offset: text[..<range.lowerBound].utf8.count,
                        utf8Length: candidate.quote.utf8.count)
                ))
        }
        try await change { state in
            guard state.enabled, state.generation == generation else {
                throw PersonalMemoryError.staleUpdate
            }
            // Retain matching links so approved facts keep their identity and review state.
            let keys = Set(validated.map { memoryKey($0.0.statement) })
            for i in state.records.indices where state.records[i].origin == .automatic {
                let keep = keys.contains(memoryKey(state.records[i].statement))
                state.records[i].sources.removeAll {
                    $0.entryID == entry.id && (!keep || $0.textRevision != revision)
                }
            }
            for (candidate, source) in validated {
                let key = memoryKey(candidate.statement)
                if let suppressed = state.suppressed[entry.id + ":" + revision],
                    suppressed.contains(memoryRevision(key)) || suppressed.contains("*")
                {
                    continue
                }
                // A correction attached to this source takes precedence over extraction.
                if state.records.contains(where: {
                    $0.origin == .user && $0.sources.contains(where: { $0.entryID == entry.id })
                }) {
                    continue
                }
                if let i = state.records.firstIndex(where: {
                    memoryKey($0.statement) == key && $0.category == candidate.category
                }) {
                    if state.records[i].origin == .user { continue }
                    state.records[i].processingVersion = version
                    if !state.records[i].sources.contains(source) {
                        state.records[i].sources.append(source)
                    }
                    state.records[i].asOf = state.records[i].sources.compactMap(\.date).max()
                    if state.records[i].state == .outdated {
                        state.records[i].state = .unreviewed
                    }
                } else {
                    state.records.append(
                        PersonalMemory(
                            id: UUID(), statement: candidate.statement,
                            category: candidate.category, asOf: source.date, sources: [source],
                            origin: .automatic,
                            state: .unreviewed, processingVersion: version))
                }
            }
            for i in state.records.indices
            where state.records[i].origin == .automatic && state.records[i].sources.isEmpty {
                state.records[i].state = .outdated
            }
            state.processed[entry.id] = entry.fingerprint + ":" + revision + ":" + version
        }
    }

    /// A transient host-side revision, never included in the model input or diagnostics.
    public func selectionRevision() throws -> String {
        struct SelectionState: Encodable {
            let enabled: Bool
            let generation: UUID
            let records: [PersonalMemory]
        }
        let state = try read(database())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return memoryRevision(
            String(
                decoding: try encoder.encode(
                    SelectionState(
                        enabled: state.enabled, generation: state.generation, records: state.records
                    )), as: UTF8.self))
    }

    /// Generation may spend time loading weights after ranking. Recheck store state and the
    /// selected automatic sources without loading embedding weights alongside the answer model.
    public func validateProfile(
        _ profile: PersonalMemoryProfile, revision: String,
        sourceURL: URL = JournalReader().sourceURL
    ) throws -> Bool {
        guard try selectionRevision() == revision else { return false }
        struct Item: Decodable { let id: UUID }
        let ids = Set(
            try JSONDecoder().decode([Item].self, from: Data(profile.text.utf8)).map(\.id))
        let selected = try read(database()).records.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { return false }
        guard try supportedRecords(selected, sourceURL: sourceURL).count == ids.count else {
            return false
        }
        // Another window owns a different store actor for the same private database.
        // Detect a store change that happened while selected sources were being reopened.
        return try selectionRevision() == revision
    }

    /// Select only supported, question-relevant background. No byte cap is applied before
    /// ranking; the generation layer fits these whole records with the actual tokenizer.
    public func profile(
        for question: String, embeddings: any IdentifiedJournalTextEmbedding,
        reuseCachedVectors: Bool = true, sourceURL: URL = JournalReader().sourceURL
    ) async throws -> PersonalMemoryProfile {
        try Task.checkCancellation()
        let initial = try read(database())
        guard initial.enabled else { return PersonalMemoryProfile() }
        let supported = try supportedRecords(initial.records, sourceURL: sourceURL)
        let omitted =
            initial.records.filter { $0.state == .active || $0.state == .unreviewed }.count
            - supported.count
        guard !supported.isEmpty else { return PersonalMemoryProfile(omittedCount: omitted) }
        let space = try await embeddings.embeddingSpace()
        let query = try EmbeddingVector.normalized(try await embeddings.embedQuery(question))
        guard query.count == space.dimensions else { throw SemanticRetrievalError.invalidVector }
        let cache = reuseCachedVectors ? embeddingCache : nil
        let ticket = try await cache?.begin(space: space)
        do {
            var epoch: String?
            if let cache, let ticket {
                epoch = try await cache.prepareMemories(
                    namespace: vectorNamespace, records: supported, space: space, ticket: ticket)
            }
            var scored: [(memory: PersonalMemory, score: Double)] = []
            for memory in supported {
                try Task.checkCancellation()
                let revision = try await cache?.memoryRevision(memory.statement)
                var vector: [Double]?
                if let cache, let ticket, let epoch, let revision {
                    vector = try await cache.memoryVector(
                        namespace: vectorNamespace, id: memory.id, revision: revision,
                        space: space, epoch: epoch, ticket: ticket)
                }
                if vector == nil {
                    let raw = try await embeddings.embedDocument(memory.statement)
                    let normalized = try EmbeddingVector.normalized(raw)
                    guard normalized.count == space.dimensions else {
                        throw SemanticRetrievalError.invalidVector
                    }
                    if let cache, let ticket, let epoch, let revision {
                        try await cache.storeMemoryVector(
                            raw, namespace: vectorNamespace, id: memory.id, revision: revision,
                            space: space, epoch: epoch, ticket: ticket)
                    }
                    vector = normalized
                }
                guard let vector else { throw SemanticRetrievalError.invalidVector }
                let score = zip(query, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
                scored.append((memory, score))
            }
            if let cache, let ticket { await cache.end(ticket) }
            try Task.checkCancellation()
            // Actor methods can interleave during native/cache awaits. Never return a profile
            // from a store revision that has since been edited, disabled or forgotten.
            let latest = try read(database())
            guard latest.generation == initial.generation, latest.enabled,
                latest.records == initial.records
            else {
                throw PersonalMemoryError.staleUpdate
            }
            let currentIDs = Set(try supportedRecords(supported, sourceURL: sourceURL).map(\.id))
            return try PersonalMemorySelection.profile(
                scored.filter { currentIDs.contains($0.memory.id) },
                omittedCount: omitted + supported.count - currentIDs.count)
        } catch {
            if let cache, let ticket { await cache.end(ticket) }
            throw error
        }
    }

    /// Original reads and SQLite handles stay on the store's actor, never the main actor.
    private func supportedRecords(_ records: [PersonalMemory], sourceURL: URL) throws
        -> [PersonalMemory]
    {
        let reader = JournalReader(sourceURL: sourceURL)
        var validSources: [String: Bool] = [:]
        return try records.filter { record in
            try Task.checkCancellation()
            guard record.state == .active || record.state == .unreviewed else { return false }
            if record.origin == .user { return true }
            for source in record.sources {
                let key = source.entryID + ":" + source.textRevision
                if validSources[key] == nil {
                    let current = try? reader.openEntry(
                        uuid: source.uuid, sourceID: source.sourceID)
                    validSources[key] =
                        current.map { memoryRevision($0.text) == source.textRevision } ?? false
                }
                if validSources[key] == true { return true }
            }
            return false
        }
    }
}
