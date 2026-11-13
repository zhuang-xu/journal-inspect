import Foundation
import JournalLlama
import llama

/// Owns native resources; access is serialized by LocalEmbeddingModel.
final class EmbeddingEngine {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private static let maximumTokens: Int32 = 2048
    private static let maximumInputBytes = 64 * 1024

    init(url: URL) throws {
        LlamaRuntime.initialize()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(url.path, parameters) else {
            throw EmbeddingError.modelUnavailable
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(Self.maximumTokens)
        contextParameters.n_batch = UInt32(Self.maximumTokens)
        contextParameters.n_ubatch = UInt32(Self.maximumTokens)
        contextParameters.n_seq_max = 1
        contextParameters.embeddings = true
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_LAST
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw EmbeddingError.contextUnavailable
        }
        self.model = model
        self.context = context
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    var dimensions: Int { Int(llama_model_n_embd_out(model)) }

    func embed(_ text: String) throws -> [Float] {
        var tokens = try tokenize(text)

        llama_memory_clear(llama_get_memory(context), true)
        defer { llama_memory_clear(llama_get_memory(context), true) }
        let result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard result == 0, let pointer = llama_get_embeddings_seq(context, 0) else {
            throw EmbeddingError.inferenceFailed
        }
        return try normalizedVector(from: pointer)
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingError.emptyInput
        }
        // Bound UTF-8 allocation and reject truncation; the retrieval layer will split long entries.
        guard text.utf8.count <= Self.maximumInputBytes else { throw EmbeddingError.inputTooLong }
        let vocabulary = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: Int(Self.maximumTokens))
        let count = text.withCString { pointer in
            llama_tokenize(
                vocabulary, pointer, Int32(text.utf8.count), &tokens, Self.maximumTokens, true,
                false)
        }
        guard count > 0, count <= Self.maximumTokens else { throw EmbeddingError.inputTooLong }
        return Array(tokens.prefix(Int(count)))
    }

    private func normalizedVector(from pointer: UnsafePointer<Float>) throws -> [Float] {
        let dimensions = Int(llama_model_n_embd_out(model))
        var vector = Array(UnsafeBufferPointer(start: pointer, count: dimensions))
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0, vector.allSatisfy({ $0.isFinite }) else {
            throw EmbeddingError.invalidVector
        }
        for index in vector.indices { vector[index] /= Float(norm) }
        return vector
    }
}
