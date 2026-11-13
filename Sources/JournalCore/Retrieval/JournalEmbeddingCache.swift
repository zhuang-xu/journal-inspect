import CryptoKit
import Darwin
import Foundation

/// Private derived vectors only. No raw journal text, questions or query vectors are stored.
/// SQLite handles remain actor-local; inference never runs inside a transaction.
public actor JournalEmbeddingCache {
    public static var defaultDirectory: URL {
        JournalMetadataStore.defaultDirectory.appendingPathComponent("Retrieval")
    }
    public let directory: URL
    private var connection: Database?
    private var writer: (ticket: UUID, epoch: String, fd: Int32)?
    private var latestStatus: JournalCacheStatus?

    public init(directory: URL = JournalEmbeddingCache.defaultDirectory) {
        self.directory = directory
    }

    deinit {
        if let writer {
            flock(writer.fd, LOCK_UN)
            close(writer.fd)
        }
    }

    private func db() throws -> Database {
        if let connection { return connection }
        do {
            let url = try PrivateStoreFile.prepare(in: directory, named: "embeddings.sqlite3")
            let database = try Database(url.path, readOnly: false)
            let app = try database.scalar("PRAGMA application_id")
            let version = try database.scalar("PRAGMA user_version")
            let count = try database.scalar("SELECT count(*) FROM sqlite_master WHERE type='table'")
            guard
                (app == "0" && version == "0" && count == "0")
                    || (app == "1246645301" && ["1", "2"].contains(version))
            else {
                throw JournalCacheError.storageUnavailable
            }
            try database.execute(
                "PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY"
            )
            try database.transaction {
                try database.execute(Self.schema)
                try Statement(database, "INSERT OR IGNORE INTO cache_settings VALUES('epoch',?)")
                    .execute([UUID().uuidString])
                try Statement(database, "INSERT OR IGNORE INTO cache_settings VALUES('key',?)")
                    .executeValues([
                        .blob(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
                    ])
            }
            connection = database
            return database
        } catch { throw JournalCacheError.storageUnavailable }
    }

    // Remap only cache I/O failures. Source/model failures never enter this helper.
    private func storage<T>(_ body: (Database) throws -> T) throws -> T {
        do { return try body(db()) } catch let error as JournalCacheError {
            throw error
        } catch is CancellationError { throw CancellationError() } catch let error
            as SemanticRetrievalError
        { throw error } catch { throw JournalCacheError.storageUnavailable }
    }

    func begin(space: EmbeddingSpace) throws -> UUID {
        guard writer == nil else { throw JournalCacheError.busy }
        return try storage { db in
            let path = directory.appendingPathComponent("writer.lock").path
            let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw JournalCacheError.storageUnavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw JournalCacheError.busy
            }
            do {
                try db.transaction {
                    // The advisory lock excludes other updaters before cleaning abandoned drafts.
                    try db.execute("DELETE FROM entry_versions WHERE complete=0")
                    try Statement(db, "INSERT OR IGNORE INTO embedding_spaces VALUES(?,?,?)")
                        .execute([try space.id, try space.json, String(space.dimensions)])
                    let descriptor = try Statement(
                        db,
                        "SELECT descriptor_json,dimensions FROM embedding_spaces WHERE space_id=?")
                    try descriptor.bind([try space.id])
                    guard try descriptor.next(), descriptor.text(0) == (try space.json),
                        descriptor.integer(1) == space.dimensions
                    else { throw JournalCacheError.invalidCache }
                }
                let ticket = UUID()
                writer = (
                    ticket, try db.scalar("SELECT value FROM cache_settings WHERE key='epoch'"), fd
                )
                return ticket
            } catch {
                flock(fd, LOCK_UN)
                close(fd)
                throw error
            }
        }
    }
    func end(_ ticket: UUID) {
        guard let writer, writer.ticket == ticket else { return }
        flock(writer.fd, LOCK_UN)
        close(writer.fd)
        self.writer = nil
    }
    private func check(_ ticket: UUID, _ db: Database) throws {
        try Task.checkCancellation()
        guard let writer, writer.ticket == ticket,
            try db.scalar("SELECT value FROM cache_settings WHERE key='epoch'") == writer.epoch
        else {
            throw JournalCacheError.staleUpdate
        }
    }
    public func clear() throws {
        try storage { db in
            try db.transaction {
                try Statement(db, "UPDATE cache_settings SET value=? WHERE key='epoch'")
                    .execute([UUID().uuidString])
                try db.execute(
                    "DELETE FROM memory_vectors; DELETE FROM memory_epochs; DELETE FROM entry_versions; DELETE FROM embedding_spaces; DELETE FROM cache_coverage"
                )
                try Statement(db, "UPDATE cache_settings SET value=? WHERE key='key'")
                    .executeValues([
                        .blob(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
                    ])
            }
        }
        latestStatus = nil
    }
    func revision(_ text: String) throws -> Data {
        try keyedRevision(text, domain: "journal-cache-body-v1")
    }
    private func keyedRevision(_ text: String, domain: String) throws -> Data {
        try storage { db in
            let query = try Statement(db, "SELECT value FROM cache_settings WHERE key='key'")
            guard try query.next(), let data = query.data(0), data.count == 32 else {
                throw JournalCacheError.invalidCache
            }
            var mac = HMAC<SHA256>(key: SymmetricKey(data: data))
            mac.update(data: Data(domain.utf8))
            var length = UInt64(text.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { mac.update(data: Data($0)) }
            mac.update(data: Data(text.utf8))
            return Data(mac.finalize())
        }
    }
    /// Memory statements use a separate domain from original Journal body revisions.
    func memoryRevision(_ text: String) throws -> Data {
        try keyedRevision(text, domain: "journal-cache-memory-statement-v1")
    }

    func invalidateMemories(namespace: String, ids: [UUID]?) throws {
        try storage { db in
            try db.transaction {
                try Statement(
                    db,
                    "INSERT INTO memory_epochs VALUES(?,?) ON CONFLICT(namespace) DO UPDATE SET epoch=excluded.epoch"
                )
                .execute([namespace, UUID().uuidString])
                if let ids {
                    for id in ids {
                        try Statement(
                            db, "DELETE FROM memory_vectors WHERE namespace=? AND memory_id=?"
                        )
                        .execute([namespace, id.uuidString])
                    }
                } else {
                    try Statement(db, "DELETE FROM memory_vectors WHERE namespace=?").execute([
                        namespace
                    ])
                }
            }
        }
    }

    func prepareMemories(
        namespace: String, records: [PersonalMemory], space: EmbeddingSpace, ticket: UUID
    ) throws -> String {
        let spaceID = try space.id
        let revisions = try Dictionary(
            uniqueKeysWithValues: records.map {
                ($0.id.uuidString, try memoryRevision($0.statement))
            })
        return try storage { db in
            try db.transaction {
                try check(ticket, db)
                try Statement(db, "INSERT OR IGNORE INTO memory_epochs VALUES(?,?)")
                    .execute([namespace, UUID().uuidString])
                let rows = try Statement(
                    db,
                    "SELECT memory_id,statement_revision,space_id FROM memory_vectors WHERE namespace=?"
                )
                try rows.bind([namespace])
                var removed: [String] = []
                while try rows.next() {
                    guard let id = rows.text(0) else { throw JournalCacheError.invalidCache }
                    if revisions[id] != rows.data(1) || rows.text(2) != spaceID {
                        removed.append(id)
                    }
                }
                for id in removed {
                    try Statement(
                        db, "DELETE FROM memory_vectors WHERE namespace=? AND memory_id=?"
                    )
                    .execute([namespace, id])
                }
                let epoch = try Statement(db, "SELECT epoch FROM memory_epochs WHERE namespace=?")
                try epoch.bind([namespace])
                guard try epoch.next(), let value = epoch.text(0) else {
                    throw JournalCacheError.invalidCache
                }
                return value
            }
        }
    }

    private func checkMemory(namespace: String, epoch: String, ticket: UUID, db: Database) throws {
        try check(ticket, db)
        let query = try Statement(db, "SELECT epoch FROM memory_epochs WHERE namespace=?")
        try query.bind([namespace])
        guard try query.next(), query.text(0) == epoch else { throw JournalCacheError.staleUpdate }
    }

    func memoryVector(
        namespace: String, id: UUID, revision: Data, space: EmbeddingSpace, epoch: String,
        ticket: UUID
    ) throws -> [Double]? {
        try storage { db in
            try checkMemory(namespace: namespace, epoch: epoch, ticket: ticket, db: db)
            let query = try Statement(
                db,
                "SELECT vector FROM memory_vectors WHERE namespace=? AND memory_id=? AND statement_revision=? AND space_id=?"
            )
            try query.bindValues([
                .text(namespace), .text(id.uuidString), .blob(revision), .text(try space.id),
            ])
            guard try query.next(), let data = query.data(0) else { return nil }
            // A damaged derived vector is a miss; the current statement will be re-embedded.
            return try? VectorCodec.decode(data, dimensions: space.dimensions)
        }
    }

    func storeMemoryVector(
        _ vector: [Float], namespace: String, id: UUID, revision: Data,
        space: EmbeddingSpace, epoch: String, ticket: UUID
    ) throws {
        let data = try VectorCodec.encode(vector, dimensions: space.dimensions)
        try storage { db in
            try db.transaction {
                try checkMemory(namespace: namespace, epoch: epoch, ticket: ticket, db: db)
                try Statement(db, "INSERT OR REPLACE INTO memory_vectors VALUES(?,?,?,?,?)")
                    .executeValues([
                        .text(namespace), .text(id.uuidString), .blob(revision),
                        .text(try space.id), .blob(data),
                    ])
            }
        }
    }

    struct Header: Sendable {
        let version: Int64
        let fingerprint: String
        let revision: Data
        let date: Date?
        let count: Int
    }
    func header(space: EmbeddingSpace, entry: JournalEntry) throws -> Header? {
        try storage { db in
            let q = try Statement(
                db,
                "SELECT version_id,fingerprint,revision,effective_date,passage_count FROM entry_versions WHERE space_id=? AND source_id=? AND uuid=? AND complete=1 ORDER BY version_id DESC LIMIT 1"
            )
            try q.bind([try space.id, entry.sourceID, entry.uuid])
            guard try q.next(), let revision = q.data(2), revision.count == 32 else { return nil }
            let version = q.integer(0)
            let vectors = try Statement(
                db,
                "SELECT ordinal,utf8_offset,utf8_length,vector FROM passage_vectors WHERE version_id=? ORDER BY ordinal"
            )
            try vectors.bind([String(version)])
            var count = 0
            var end = 0
            while try vectors.next() {
                guard vectors.integer(0) == count, vectors.integer(1) >= end,
                    vectors.integer(2) > 0, vectors.integer(2) <= JournalPassages.maximumBytes,
                    let blob = vectors.data(3),
                    (try? VectorCodec.decode(blob, dimensions: space.dimensions)) != nil
                else { return nil }
                end = Int(vectors.integer(1) + vectors.integer(2))
                count += 1
            }
            guard count == q.integer(4) else { return nil }
            return Header(
                version: version, fingerprint: q.text(1)!, revision: revision,
                date: q.number(3).map(Date.init(timeIntervalSince1970:)), count: count)
        }
    }
    func matchesLayout(version: Int64, passages: [JournalPassages.Located]) throws -> Bool {
        try storage { db in
            let q = try Statement(
                db,
                "SELECT utf8_offset,utf8_length FROM passage_vectors WHERE version_id=? ORDER BY ordinal"
            )
            try q.bind([String(version)])
            var ordinal = 0
            while try q.next() {
                guard ordinal < passages.count,
                    q.integer(0) == passages[ordinal].offset,
                    q.integer(1) == passages[ordinal].length
                else { return false }
                ordinal += 1
            }
            return ordinal == passages.count
        }
    }

    func reconcile(_ manifest: JournalMetadataManifest, space: EmbeddingSpace, ticket: UUID) throws
    {
        try storage { db in
            try db.transaction {
                try check(ticket, db)
                try db.execute(
                    "CREATE TEMP TABLE IF NOT EXISTS manifest(uuid TEXT PRIMARY KEY,fingerprint TEXT); DELETE FROM manifest"
                )
                let insert = try Statement(db, "INSERT INTO manifest VALUES(?,?)")
                for entry in manifest.entries {
                    try insert.execute([entry.uuid, entry.fingerprint])
                }
                let spaceID = try space.id
                let source = manifest.receipt.sourceID
                try Statement(
                    db,
                    "DELETE FROM entry_versions WHERE space_id=? AND source_id=? AND NOT EXISTS(SELECT 1 FROM manifest WHERE manifest.uuid=entry_versions.uuid)"
                )
                .execute([spaceID, source])
                try Statement(
                    db,
                    "UPDATE entry_versions SET current=0 WHERE space_id=? AND source_id=? AND NOT EXISTS(SELECT 1 FROM manifest WHERE manifest.uuid=entry_versions.uuid AND manifest.fingerprint=entry_versions.fingerprint)"
                )
                .execute([spaceID, source])
            }
        }
    }
    func draft(
        entry: JournalEntry, space: EmbeddingSpace, revision: Data, date: Date?, count: Int,
        ticket: UUID
    ) throws -> Int64 {
        try storage { db in
            try db.transaction {
                try check(ticket, db)
                try Statement(
                    db,
                    "UPDATE entry_versions SET current=0 WHERE space_id=? AND source_id=? AND uuid=?"
                )
                .execute([try space.id, entry.sourceID, entry.uuid])
                try Statement(
                    db,
                    "INSERT INTO entry_versions(space_id,source_id,uuid,fingerprint,revision,effective_date,passage_count,complete,current) VALUES(?,?,?,?,?,?,?,0,0)"
                )
                .executeValues([
                    .text(try space.id), .text(entry.sourceID), .text(entry.uuid),
                    .text(entry.fingerprint), .blob(revision),
                    date.map { .real($0.timeIntervalSince1970) } ?? .null, .integer(Int64(count)),
                ])
                return Int64(try db.scalar("SELECT last_insert_rowid()"))!
            }
        }
    }
    func append(
        version: Int64, ordinal: Int, passage: JournalPassages.Located, vector: [Float],
        space: EmbeddingSpace, ticket: UUID
    ) throws {
        let blob = try VectorCodec.encode(vector, dimensions: space.dimensions)
        try storage { db in
            try db.transaction {
                try check(ticket, db)
                try Statement(db, "INSERT INTO passage_vectors VALUES(?,?,?,?,?)")
                    .executeValues([
                        .integer(version), .integer(Int64(ordinal)),
                        .integer(Int64(passage.offset)), .integer(Int64(passage.length)),
                        .blob(blob),
                    ])
            }
        }
    }
    func publish(
        version: Int64, entry: JournalEntry, space: EmbeddingSpace, date: Date?, ticket: UUID
    ) throws {
        try storage { db in
            try db.transaction {
                try check(ticket, db)
                let count = try Statement(
                    db,
                    "SELECT passage_count,(SELECT count(*) FROM passage_vectors WHERE version_id=?) FROM entry_versions WHERE version_id=? AND space_id=? AND source_id=? AND uuid=?"
                )
                try count.bind([
                    String(version), String(version), try space.id, entry.sourceID, entry.uuid,
                ])
                guard try count.next(), count.integer(0) == count.integer(1) else {
                    throw JournalCacheError.invalidCache
                }
                try Statement(
                    db,
                    "UPDATE entry_versions SET complete=1,current=1,fingerprint=?,effective_date=? WHERE version_id=?"
                )
                .executeValues([
                    .text(entry.fingerprint), date.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .integer(version),
                ])
                try Statement(
                    db,
                    "DELETE FROM entry_versions WHERE space_id=? AND source_id=? AND uuid=? AND version_id!=?"
                )
                .execute([try space.id, entry.sourceID, entry.uuid, String(version)])
            }
        }
    }
    func invalidate(sourceID: String, uuid: String, space: EmbeddingSpace) throws {
        try storage { db in
            try Statement(
                db,
                "UPDATE entry_versions SET fingerprint='',current=0 WHERE source_id=? AND uuid=? AND space_id=?"
            )
            .execute([sourceID, uuid, try space.id])
        }
    }
    func finish(
        manifest: JournalMetadataManifest, space: EmbeddingSpace, reused: Int, rebuilt: Int,
        ticket: UUID
    ) throws {
        try storage { db in
            try db.transaction {
                try check(ticket, db)
                let receipt = manifest.receipt
                try Statement(db, "INSERT OR REPLACE INTO cache_coverage VALUES(?,?,?,?,?,?)")
                    .execute([
                        try space.id, receipt.sourceID, receipt.indexInstanceID,
                        String(receipt.generation), String(manifest.entries.count),
                        String(Date().timeIntervalSince1970),
                    ])
                // Only the successfully switched document namespace remains resident on disk.
                try Statement(db, "DELETE FROM embedding_spaces WHERE space_id!=?").execute([
                    try space.id
                ])
            }
            let passages = Int(try db.scalar("SELECT count(*) FROM passage_vectors")) ?? 0
            let size =
                (try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent("embeddings.sqlite3").path)[.size]
                as? NSNumber)?.int64Value ?? 0
            latestStatus = JournalCacheStatus(
                ready: manifest.entries.count, total: manifest.entries.count,
                passages: passages, bytes: size, checkedAt: Date(), reused: reused, rebuilt: rebuilt
            )
        }
    }
    func checkTicket(_ ticket: UUID) throws {
        try storage { try check(ticket, $0) }
    }
    public func status() -> JournalCacheStatus? { latestStatus }

    struct Candidate: Sendable {
        let score: Double
        let reference: JournalEvidenceReference
    }
    func rank(
        query: [Double], space: EmbeddingSpace, sourceID: String, request: RetrievalRequest,
        ticket: UUID
    ) throws -> [Candidate] {
        try storage { db in
            try check(ticket, db)
            let q = try Statement(
                db,
                "SELECT e.source_id,e.uuid,e.revision,e.effective_date,p.utf8_offset,p.utf8_length,p.vector FROM entry_versions e JOIN passage_vectors p ON e.version_id=p.version_id WHERE e.space_id=? AND e.source_id=? AND e.complete=1 AND e.current=1 ORDER BY e.uuid,p.ordinal"
            )
            try q.bind([try space.id, sourceID])
            var best: [Candidate] = []
            var selected: Candidate?
            func retain(_ candidate: Candidate?) {
                guard let candidate else { return }
                best.append(candidate)
                best.sort {
                    $0.score == $1.score ? $0.reference.id < $1.reference.id : $0.score > $1.score
                }
                if best.count > request.limit { best.removeLast() }
            }
            while try q.next() {
                try Task.checkCancellation()
                let id = q.text(0)! + ":" + q.text(1)!
                if selected?.reference.id != id {
                    retain(selected)
                    selected = nil
                }
                let timestamp = q.number(3)
                let date = timestamp.map(Date.init(timeIntervalSince1970:))
                // Compare in the stored epoch. A Date round trip can lose a reference-epoch ULP.
                if let start = request.start,
                    timestamp == nil || timestamp! < start.timeIntervalSince1970
                {
                    continue
                }
                if let end = request.end,
                    timestamp == nil || timestamp! >= end.timeIntervalSince1970
                {
                    continue
                }
                guard let blob = q.data(6), let revision = q.data(2), revision.count == 32,
                    q.integer(4) >= 0, q.integer(5) > 0,
                    q.integer(5) <= JournalPassages.maximumBytes
                else { throw JournalCacheError.invalidCache }
                let vector = try VectorCodec.decode(blob, dimensions: space.dimensions)
                let score = zip(query, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
                if selected == nil || score > selected!.score {
                    selected = Candidate(
                        score: score,
                        reference: JournalEvidenceReference(
                            sourceID: q.text(0)!, uuid: q.text(1)!, revision: .cached(revision),
                            date: date,
                            offset: Int(q.integer(4)), length: Int(q.integer(5))))
                }
            }
            retain(selected)
            return best
        }
    }
    public func validate(
        _ references: [JournalEvidenceReference], sourceURL: URL = JournalReader().sourceURL
    ) throws -> Bool {
        let reader = JournalReader(sourceURL: sourceURL)
        for ref in references {
            try Task.checkCancellation()
            do {
                let entry = try reader.openEntry(uuid: ref.uuid, sourceID: ref.sourceID)
                let currentRevision: JournalEvidenceReference.Revision
                switch ref.revision {
                case .transient:
                    currentRevision = JournalEvidenceReference.transientRevision(entry.text)
                case .cached:
                    currentRevision = .cached(try revision(entry.text))
                }
                guard ref.excerpt(in: entry, currentRevision: currentRevision) != nil else {
                    return false
                }
            } catch let error as JournalReaderError where error.code == "entry_unavailable" {
                return false
            }
        }
        return true
    }
    private static let schema = """
        PRAGMA application_id=1246645301; PRAGMA user_version=2;
        CREATE TABLE IF NOT EXISTS cache_settings(key TEXT PRIMARY KEY,value BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS embedding_spaces(space_id TEXT PRIMARY KEY,descriptor_json TEXT NOT NULL,dimensions INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS entry_versions(version_id INTEGER PRIMARY KEY AUTOINCREMENT,space_id TEXT NOT NULL REFERENCES embedding_spaces ON DELETE CASCADE,source_id TEXT NOT NULL,uuid TEXT NOT NULL,fingerprint TEXT NOT NULL,revision BLOB NOT NULL CHECK(length(revision)=32),effective_date REAL,passage_count INTEGER NOT NULL CHECK(passage_count>=0),complete INTEGER NOT NULL CHECK(complete IN (0,1)),current INTEGER NOT NULL CHECK(current IN (0,1)));
        CREATE INDEX IF NOT EXISTS entry_lookup ON entry_versions(space_id,source_id,uuid);
        CREATE TABLE IF NOT EXISTS passage_vectors(version_id INTEGER NOT NULL REFERENCES entry_versions ON DELETE CASCADE,ordinal INTEGER NOT NULL CHECK(ordinal>=0),utf8_offset INTEGER NOT NULL CHECK(utf8_offset>=0),utf8_length INTEGER NOT NULL CHECK(utf8_length>0),vector BLOB NOT NULL,PRIMARY KEY(version_id,ordinal));
        CREATE TABLE IF NOT EXISTS memory_epochs(namespace TEXT PRIMARY KEY,epoch TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS memory_vectors(namespace TEXT NOT NULL REFERENCES memory_epochs ON DELETE CASCADE,memory_id TEXT NOT NULL,statement_revision BLOB NOT NULL CHECK(length(statement_revision)=32),space_id TEXT NOT NULL REFERENCES embedding_spaces ON DELETE CASCADE,vector BLOB NOT NULL,PRIMARY KEY(namespace,memory_id));
        CREATE TABLE IF NOT EXISTS cache_coverage(space_id TEXT NOT NULL REFERENCES embedding_spaces ON DELETE CASCADE,source_id TEXT NOT NULL,index_instance_id TEXT NOT NULL,generation INTEGER NOT NULL,total INTEGER NOT NULL,checked_at REAL NOT NULL,PRIMARY KEY(space_id,source_id));
        """
}
