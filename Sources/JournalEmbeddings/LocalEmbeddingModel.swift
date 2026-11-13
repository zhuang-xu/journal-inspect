import CryptoKit
import Foundation
import JournalCore

/// Serializes verified native model access off the main actor. Persistence belongs to JournalCore.
public actor LocalEmbeddingModel: IdentifiedJournalTextEmbedding {
    public static let modelFilename = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    public static let runtimeVersion = "b12038"
    public static let modelSHA256 =
        "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"

    private static let queryInstruction =
        "Given a question, retrieve relevant personal journal passages that answer the question"

    private var engine: EmbeddingEngine?
    private var verifiedSpace: EmbeddingSpace?

    public init() {}

    public func load(from url: URL) throws {
        try Task.checkCancellation()
        engine = nil
        verifiedSpace = nil
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == Self.modelSHA256 else { throw EmbeddingError.modelUnavailable }
        let loaded = try EmbeddingEngine(url: url)
        engine = loaded
        verifiedSpace = EmbeddingSpace(
            weightsSHA256: checksum, dimensions: loaded.dimensions, runtime: Self.runtimeVersion)
    }

    public func embeddingSpace() throws -> EmbeddingSpace {
        guard let verifiedSpace, engine != nil else { throw EmbeddingError.modelUnavailable }
        return verifiedSpace
    }

    public func unload() {
        engine = nil
        verifiedSpace = nil
    }

    /// Returns a normalized passage vector without persisting the text.
    public func embedDocument(_ text: String) throws -> [Float] {
        try Task.checkCancellation()
        guard let engine else { throw EmbeddingError.modelUnavailable }
        return try engine.embed(text)
    }

    /// Adds Qwen’s retrieval instruction before embedding a search question.
    public func embedQuery(_ text: String) throws -> [Float] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingError.emptyInput
        }
        let input = "Instruct: \(Self.queryInstruction)\nQuery: \(text)"
        return try embedDocument(input)
    }
}
