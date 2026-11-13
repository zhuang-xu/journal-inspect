import CryptoKit
import Foundation

public enum JournalCacheError: Error {
    case storageUnavailable
    case busy
    case staleUpdate
    case sourceChanged
    case incompleteIndex
    case invalidCache
}

/// Document-space identity excludes question instructions and the answer model.
public struct EmbeddingSpace: Codable, Equatable, Sendable {
    public let weightsSHA256: String
    public let dimensions: Int
    public let runtime: String
    public let processing: String
    public init(
        weightsSHA256: String, dimensions: Int, runtime: String,
        processing: String =
            "document-raw-v1;tokenize-special-add-true-parse-false;LAST;L2;cosine;utf8-768-v1;float32-le-v1;native-rtf-v1;"
            + ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.weightsSHA256 = weightsSHA256
        self.dimensions = dimensions
        self.runtime = runtime
        self.processing = processing
    }
    var json: String {
        get throws {
            guard (1...65536).contains(dimensions) else {
                throw SemanticRetrievalError.invalidVector
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
    var id: String {
        get throws {
            SHA256.hash(data: Data(try json.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public protocol IdentifiedJournalTextEmbedding: JournalTextEmbedding {
    func embeddingSpace() async throws -> EmbeddingSpace
}

enum VectorCodec {
    static func encode(_ vector: [Float], dimensions: Int) throws -> Data {
        guard vector.count == dimensions else { throw SemanticRetrievalError.invalidVector }
        let normalized = try EmbeddingVector.normalized(vector)
        var data = Data(capacity: dimensions * 4)
        for value in normalized {
            var bits = Float(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
    static func decode(_ data: Data, dimensions: Int) throws -> [Double] {
        guard data.count == dimensions * 4 else { throw JournalCacheError.invalidCache }
        let vector: [Float] = data.withUnsafeBytes { bytes in
            (0..<dimensions).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
        do { return try EmbeddingVector.normalized(vector) } catch {
            throw JournalCacheError.invalidCache
        }
    }
}

public struct JournalEvidenceReference: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let sourceID: String
    public let uuid: String
    enum Revision: Equatable, Sendable {
        case cached(Data)
        case transient(Data)
    }

    let revision: Revision
    let date: Date?
    let offset: Int
    let length: Int

    static func transientRevision(_ text: String) -> Revision {
        // This digest stays in the in-memory reference. Persistent revisions use the cache key.
        .transient(Data(SHA256.hash(data: Data(text.utf8))))
    }

    func excerpt(in entry: LoadedJournalEntry, currentRevision: Revision) -> String? {
        guard revision == currentRevision,
            date?.timeIntervalSince1970 == entry.date?.timeIntervalSince1970,
            offset >= 0, length > 0, offset <= entry.text.utf8.count,
            length <= entry.text.utf8.count - offset
        else { return nil }
        return String(bytes: entry.text.utf8.dropFirst(offset).prefix(length), encoding: .utf8)
    }

    func expandedEvidence(
        _ passage: JournalPassages.Located, in original: String, date: Date?
    ) -> JournalEvidence {
        let expanded = JournalPassages.expanded(passage, in: original)
        return JournalEvidence(
            sourceID: sourceID, uuid: uuid, date: date, text: expanded.text,
            reference: JournalEvidenceReference(
                sourceID: sourceID, uuid: uuid, revision: revision,
                date: date, offset: expanded.offset, length: expanded.length))
    }

    var id: String { sourceID + ":" + uuid }
    public var description: String { "JournalEvidenceReference(redacted)" }
    public var debugDescription: String { description }
}

public struct JournalCacheStatus: Sendable {
    public let ready: Int
    public let total: Int
    public let passages: Int
    public let bytes: Int64
    public let checkedAt: Date?
    public let reused: Int
    public let rebuilt: Int
}
