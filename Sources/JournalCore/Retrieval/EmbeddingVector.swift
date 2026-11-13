import Foundation

/// Shared finite, nonzero vector validation for transient and persisted retrieval.
enum EmbeddingVector {
    static func normalized(_ vector: [Float]) throws -> [Double] {
        guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else {
            throw SemanticRetrievalError.invalidVector
        }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw SemanticRetrievalError.invalidVector }
        return vector.map { Double($0) / norm }
    }
}
